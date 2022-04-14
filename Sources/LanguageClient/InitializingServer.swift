import Foundation
import LanguageServerProtocol
import OperationPlus
import AnyCodable
import os.log

public enum InitializingServerError: Error {
    case noStateProvider
}

public class InitializingServer {
    public typealias InitializeParamsProvider = ((@escaping (Result<InitializeParams, Error>) -> Void) -> Void)
    public typealias ServerCapabilitiesChangedHandler = (ServerCapabilities) -> Void

    enum State {
        case uninitialized
        case initializing
        case initialized(ServerCapabilities)
        case shutdown

        var capabilities: ServerCapabilities? {
            switch self {
            case .initialized(let caps):
                return caps
            case .uninitialized, .shutdown, .initializing:
                return nil
            }
        }
    }

    private var wrappedServer: Server
    private var state: State
    private let queue: OperationQueue
    private var openDocuments: [DocumentUri]
    private let log: OSLog
    
    public var initializeParamsProvider: InitializeParamsProvider
    public var serverCapabilitiesChangedHandler: ServerCapabilitiesChangedHandler?
    public var defaultTimeout: TimeInterval = 10.0
    public var requestHandler: RequestHandler?

    public init(server: Server) {
        self.state = .uninitialized
        self.wrappedServer = server
        self.openDocuments = []
        self.queue = OperationQueue.serialQueue(named: "com.chimehq.LanguageClient.InitializingServer")
        self.log = OSLog(subsystem: "com.chimehq.LanguageClient", category: "InitializingServer")

        self.initializeParamsProvider = { block in block(.failure(InitializingServerError.noStateProvider)) }

        wrappedServer.requestHandler = { [unowned self] in self.handleRequest($0, completionHandler: $1) }
    }

    public func getCapabilities(_ block: @escaping (ServerCapabilities?) -> Void) {
        queue.addOperation {
            let caps = self.state.capabilities

            block(caps)
        }
    }
}

extension InitializingServer {
    private func makeInitializationOperation() -> Operation {
        let initOp = InitializationOperation(server: wrappedServer, initializeParamsProvider: initializeParamsProvider)

        initOp.resultCompletionBlock = { result in
            // verify we are in the right state here
            switch self.state {
            case .initializing:
                break
            default:
                assertionFailure()
            }

            switch result {
            case .failure(let error):
                os_log("failed to initialize: %{public}@", log: self.log, type: .error, String(describing: error))

                self.state = .uninitialized
            case .success(let response):
                let caps = response.capabilities


                self.state = .initialized(caps)

                self.serverCapabilitiesChangedHandler?(caps)
            }
        }

        return initOp
    }

    private func enqueueInitDependantOperation(_ op: Operation) {
        queue.addOperation {
            switch self.state {
            case .initialized, .initializing, .shutdown:
                break
            case .uninitialized:
                let initOp = self.makeInitializationOperation()

                self.queue.addOperation(initOp)

                op.addDependency(initOp)

                self.state = .initializing
            }

            self.queue.addOperation(op)
        }
    }
}

extension InitializingServer: Server {
    private func handleRequest(_ request: ServerRequest, completionHandler: @escaping (ServerResult<AnyCodable>) -> Void) -> Void {
        queue.addOperation {
            guard case .initialized(let caps) = self.state else {
                assertionFailure("received a request without being initialized")
                return
            }

            var newCaps = caps

            do {
                switch request {
                case .clientRegisterCapability(let params):
                    try newCaps.applyRegistrations(params.registrations)
                case .clientUnregisterCapability(let params):
                    try newCaps.applyUnregistrations(params.unregistrations)
                default:
                    break
                }

                if caps != newCaps {
                    self.state = .initialized(newCaps)

                    self.serverCapabilitiesChangedHandler?(newCaps)
                }
            } catch {
                completionHandler(.failure(.requestDispatchFailed(error)))
                return
            }

            guard let handler = self.requestHandler else {
                completionHandler(.failure(.handlerUnavailable(request.method.rawValue)))
                                           return
            }

            handler(request, completionHandler)
        }
    }

    public var notificationHandler: NotificationHandler? {
        get { wrappedServer.notificationHandler }
        set { wrappedServer.notificationHandler = newValue }
    }

    public func sendNotification(_ notif: ClientNotification, timeout: TimeInterval, completionHandler: @escaping (ServerError?) -> Void) {
        if case .initialized = notif {
            fatalError("Cannot send initialized to InitializingServer")
        }

        let op = AsyncBlockProducerOperation<ServerError?>(timeout: timeout) { opBlock in
            // this is pretty subtle, but we have to be very careful to return
            // the right thing here, as opBlock takes a ServerError??
            self.wrappedServer.sendNotification(notif) { error in
                opBlock(.some(error))
            }
        }

        op.resultCompletionBlockBehavior = .onTimeOut(ServerError.timeout)
        op.resultCompletionBlock = completionHandler

        enqueueInitDependantOperation(op)
    }

    public func sendNotification(_ notif: ClientNotification, completionHandler: @escaping (ServerError?) -> Void) {
        sendNotification(notif, timeout: defaultTimeout, completionHandler: completionHandler)
    }

    public func sendRequest<Response>(_ request: ClientRequest, timeout: TimeInterval, completionHandler: @escaping (ServerResult<Response>) -> Void) where Response : Decodable, Response : Encodable {
        if case .initialize = request {
            fatalError("Cannot initialize to InitializingServer")
        }

        let op = AsyncBlockProducerOperation<ServerResult<Response>>(timeout: timeout) { opBlock in
            self.wrappedServer.sendRequest(request, completionHandler: { (result: ServerResult<Response>) in
                if case .success = result, case .shutdown = request {
                    self.state = .shutdown
                }

                opBlock(result)
            })
        }

        op.resultCompletionBlockBehavior = .onTimeOut(.failure(ServerError.timeout))
        op.resultCompletionBlock = completionHandler

        enqueueInitDependantOperation(op)
    }

    public func sendRequest<Response>(_ request: ClientRequest, completionHandler: @escaping (ServerResult<Response>) -> Void) where Response : Decodable, Response : Encodable {
        sendRequest(request, timeout: defaultTimeout, completionHandler: completionHandler)
    }
}
