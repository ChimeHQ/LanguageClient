import Foundation
import LanguageServerProtocol
import OperationPlus
import JSONRPC
import AnyCodable
import os.log

public enum RestartingServerError: Error {
    case noProvider
    case serverStopped
    case noURIMatch(DocumentUri)
    case noTextDocumentForURI(DocumentUri)
}

public class RestartingServer {
    public typealias ExecutionParamsProvider = (@escaping (Result<Process.ExecutionParameters, Error>) -> Void) -> Void
    public typealias TextDocumentItemProvider = ((DocumentUri, @escaping (Result<TextDocumentItem, Error>) -> Void) -> Void)
    public typealias InitializeParamsProvider = InitializingServer.InitializeParamsProvider
    public typealias ServerCapabilitiesChangedHandler = InitializingServer.ServerCapabilitiesChangedHandler
    
    enum State {
        case notStarted
        case restartNeeded
        case running(InitializingServer)
        case shuttingDown
        case stopped(Date)
    }

    private var state: State
    private var openDocumentURIs: Set<DocumentUri>
    private let queue: OperationQueue
    private let log: OSLog

    public var requestHandler: RequestHandler?
    public var notificationHandler: NotificationHandler?
    public var executionParamsProvider: ExecutionParamsProvider
    public var initializeParamsProvider: InitializeParamsProvider
    public var textDocumentItemProvider: TextDocumentItemProvider
    public var serverCapabilitiesChangedHandler: ServerCapabilitiesChangedHandler?

    public var logMessages: Bool = false

    public init(executionParameters: Process.ExecutionParameters? = nil) {
        self.state = .notStarted
        self.openDocumentURIs = Set()
        self.queue = OperationQueue.serialQueue(named: "com.chimehq.LanguageClient-RestartingServer")
        self.log = OSLog(subsystem: "com.chimehq.LanguageClient", category: "RestartingServer")

        self.executionParamsProvider = { block in
            if let params = executionParameters {
                block(.success(params))
            } else {
                block(.failure(RestartingServerError.noProvider))
            }
        }

        self.initializeParamsProvider = { block in
            block(.failure(RestartingServerError.noProvider))
        }

        self.textDocumentItemProvider = { _, block in
            block(.failure(RestartingServerError.noProvider))
        }
    }

    public func getCapabilities(_ block: @escaping (LanguageServerProtocol.ServerCapabilities?) -> Void) {
        queue.addOperation {
            switch self.state {
            case .running(let initServer):
                initServer.getCapabilities(block)
            case .notStarted, .shuttingDown, .stopped, .restartNeeded:
                block(nil)
            }
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

    private func reopenDocuments(for server: Server, completionHandler: @escaping () -> Void) {
        let group = DispatchGroup()

        for uri in self.openDocumentURIs {
            group.enter()

            os_log("Trying to reopen document %{public}@", log: self.log, type: .info, uri)

            textDocumentItemProvider(uri, { result in
                switch result {
                case .failure:
                    break
                case .success(let item):
                    let params = DidOpenTextDocumentParams(textDocument: item)

                    server.didOpenTextDocument(params: params) { error in
                        if let error = error {
                            os_log("Failed to reopen document %{public}@: %{public}@", log: self.log, type: .error, uri, error.localizedDescription)
                        }
                    }

                    group.leave()
                }
            })
        }

        group.notify(queue: .global(), execute: completionHandler)
    }

    private func makeNewServer(with params: Process.ExecutionParameters) -> InitializingServer {
        let processServer = LocalProcessServer(executionParameters: params)

        processServer.terminationHandler = { [unowned self] in self.serverBecameUnavailable() }

        processServer.logMessages = self.logMessages

        let initServer = InitializingServer(server: processServer)

        initServer.notificationHandler = { [unowned self] in self.handleNotification($0, completionHandler: $1) }
        initServer.requestHandler = { [unowned self] in self.handleRequest($0, completionHandler: $1) }
        initServer.initializeParamsProvider = { [unowned self] in self.initializeParamsProvider($0) }
        initServer.serverCapabilitiesChangedHandler = { [unowned self] in self.serverCapabilitiesChangedHandler?($0) }

        return initServer
    }

    private func startNewServer(completionHandler: @escaping (Result<InitializingServer, Error>) -> Void) {
        executionParamsProvider({ result in
            let serverResult = result.map { self.makeNewServer(with: $0) }

            completionHandler(serverResult)
        })
    }

    private func startNewServerAndAdjustState(reopenDocs: Bool, completionHandler: @escaping (Result<InitializingServer, Error>) -> Void) {
        startNewServer { result in
            switch result {
            case .failure(let error):
                completionHandler(.failure(error))
            case .success(let server):
                self.state = .running(server)

                guard reopenDocs else {
                    completionHandler(.success(server))
                    return
                }

                self.reopenDocuments(for: server) {
                    completionHandler(.success(server))
                }
            }
        }
    }

    private func startServerIfNeeded(block: @escaping (Result<InitializingServer, Error>) -> Void) {
        let op = AsyncBlockProducerOperation<Result<InitializingServer, Error>> { opBlock in
            switch self.state {
            case .notStarted:
                self.startNewServerAndAdjustState(reopenDocs: false, completionHandler: opBlock)
            case .restartNeeded:
                self.startNewServerAndAdjustState(reopenDocs: true, completionHandler: opBlock)
            case .running(let server):
                opBlock(.success(server))
            case .stopped, .shuttingDown:
                opBlock(.failure(RestartingServerError.serverStopped))
            }
        }

        op.resultCompletionBlock = block

        queue.addOperation(op)
    }

    private func serverBecameUnavailable() {
        os_log("Server became unavailable", log: self.log, type: .info)

        let date = Date()

        queue.addOperation {
            self.state = .stopped(date)

            self.queue.addOperation(afterDelay: 5.0) {
                guard case .stopped = self.state else {
                    os_log("State change during restart", log: self.log, type: .error)
                    return
                }

                self.state = .notStarted
            }
        }
    }

    private func handleDidOpen(_ params: DidOpenTextDocumentParams) {
        let uri = params.textDocument.uri

        assert(openDocumentURIs.contains(uri) == false)

        self.openDocumentURIs.insert(uri)
    }

    private func handleDidClose(_ params: DidCloseTextDocumentParams) {
        let uri = params.textDocument.uri

        assert(openDocumentURIs.contains(uri))

        openDocumentURIs.remove(uri)
    }

    private func processOutboundNotification(_ notification: ClientNotification) {
        switch notification {
        case .didOpenTextDocument(let params):
            self.handleDidOpen(params)
        case .didCloseTextDocument(let params):
            self.handleDidClose(params)
        default:
            break
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
                os_log("Unable to get server %{public}@", log: self.log, type: .info, error.localizedDescription)

                completionHandler(.serverUnavailable)
            case .success(let server):

                self.processOutboundNotification(notif)

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
                os_log("Unable to get server %{public}@", log: self.log, type: .info, error.localizedDescription)

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
