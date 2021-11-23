import Foundation
import LanguageServerProtocol
import OperationPlus
import JSONRPC
import AnyCodable
import SwiftLSPClient

public class RestartingServer {
    public typealias ExecutionParamsProvider = (@escaping (Result<Process.ExecutionParameters, Error>) -> Void) -> Void

    enum State {
        case notStarted
        case running(InitializingServer)
        case shuttingDown
        case stopped(Date)
    }

    private var state: State
    private let queue: OperationQueue

    public var requestHandler: RequestHandler?
    public var notificationHandler: NotificationHandler?
    public var executionParamsProvider: ExecutionParamsProvider
    public var startupStateProvider: InitializingServer.StartupStateProvider
    public var serverCapabilitiesChangedHandler: InitializingServer.ServerCapabilitiesChangedHandler?

    public var logMessages: Bool = false

    public init(executionParameters: Process.ExecutionParameters? = nil) {
        self.state = .notStarted
        self.queue = OperationQueue.serialQueue(named: "com.chimehq.RestartingServer")

        self.executionParamsProvider = { block in
            if let params = executionParameters {
                block(.success(params))
            } else {
                block(.failure(NSError(domain: "blah", code: 1)))
            }
        }

        self.startupStateProvider = { block in
            block(.failure(ServerError.handlerUnavailable("Startup State")))
        }
    }

    public func shutdownAndExit(block: @escaping (ServerError?) -> Void) {
        queue.addOperation {
            guard case .running(let server) = self.state else {
                block(ServerError.serverUnavailable)
                return
            }

            self.state = .shuttingDown

            let op = ShutdownOperation(server: server)

            self.queue.addOperation(op)

            op.resultCompletionBlock = block
        }
    }
    
    private func startServerIfNeeded(block: @escaping (Result<Server, Error>) -> Void) {
        let op = AsyncBlockProducerOperation<Result<Server, Error>> { opBlock in
            switch self.state {
            case .notStarted:
                self.startNewServer { result in
                    if case .success(let server) = result {
                        self.state = .running(server)
                    }

                    opBlock(result.map({ $0 as Server }))
                }
            case .running(let server):
                opBlock(.success(server))
            case .stopped, .shuttingDown:
                opBlock(.failure(ServerError.serverUnavailable))
            }
        }

        op.resultCompletionBlock = block

        queue.addOperation(op)
    }

    private func makeNewServer(with params: Process.ExecutionParameters) -> InitializingServer {
        let processServer = LocalProcessServer(executionParameters: params)

        processServer.terminationHandler = { [unowned self] in self.serverBecameUnavailable() }

        processServer.logMessages = self.logMessages

        let initServer = InitializingServer(server: processServer)

        initServer.notificationHandler = { [unowned self] in self.handleNotification($0, completionHandler: $1) }
        initServer.requestHandler = { [unowned self] in self.handleRequest($0, completionHandler: $1) }
        initServer.startupStateProvider = { [unowned self] in self.startupStateProvider($0) }
        initServer.serverCapabilitiesChangedHandler = { [unowned self] in self.serverCapabilitiesChangedHandler?($0) }

        return initServer
    }

    private func startNewServer(completionHandler: @escaping (Result<InitializingServer, Error>) -> Void) {
        executionParamsProvider({ result in
            let serverResult = result.map { self.makeNewServer(with: $0) }

            completionHandler(serverResult)
        })
    }

    private func serverBecameUnavailable() {
        print("server became unavailable")
        let date = Date()

        queue.addOperation {
            self.state = .stopped(date)

            self.queue.addOperation(afterDelay: 5.0) {
                guard case .stopped = self.state else {
                    print("state change during restart")
                    return
                }

                self.state = .notStarted
            }
        }
    }

    private func handleNotification(_ notification: ServerNotification, completionHandler: @escaping (ServerError?) -> Void) -> Void {
        queue.addOperation {
            guard let handler = self.notificationHandler else {
                completionHandler(.handlerUnavailable(notification.method.rawValue))
                return
            }

            handler(notification, completionHandler)
        }
    }

    private func handleRequest(_ request: ServerRequest, completionHandler: @escaping (ServerResult<AnyCodable>) -> Void) -> Void {
        queue.addOperation {
            guard let handler = self.requestHandler else {
                completionHandler(.failure(.handlerUnavailable(request.method.rawValue)))
                return
            }

            handler(request, completionHandler)
        }
    }
}

extension RestartingServer: Server {
    public func sendNotification(_ notif: ClientNotification, completionHandler: @escaping (ServerError?) -> Void) {
        startServerIfNeeded { result in
            switch result {
            case .failure(let error):
                print("unable to get server: \(error)")

                completionHandler(.serverUnavailable)
            case .success(let server):
                server.sendNotification(notif, completionHandler: { error in
                    if case .serverUnavailable = error {
                        self.serverBecameUnavailable()
                    }

                    completionHandler(error)
                })
            }
        }
    }

    public func sendRequest<Response: Codable>(_ request: ClientRequest, completionHandler: @escaping (ServerResult<Response>) -> Void) {
        startServerIfNeeded { result in
            switch result {
            case .failure(let error):
                print("unable to get server: \(error)")

                completionHandler(.failure(.serverUnavailable))
            case .success(let server):
                server.sendRequest(request, completionHandler: { (result: ServerResult<Response>) in
                    if case .failure(.serverUnavailable) = result {
                        self.serverBecameUnavailable()
                    }

                    completionHandler(result)
                })
            }
        }
    }
}
