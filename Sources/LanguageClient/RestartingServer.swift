import Foundation
import os.log

import JSONRPC
import LanguageServerProtocol
import OperationPlus

public enum RestartingServerError: Error {
    case noProvider
    case serverStopped
    case noURIMatch(DocumentUri)
    case noTextDocumentForURI(DocumentUri)
}

/// A `Server` wrapper that provides both transparent server-side state restoration should the underlying process crash.
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public class RestartingServer {
    public typealias ServerProvider = () async throws -> Server
    public typealias TextDocumentItemProvider = (DocumentUri) async throws -> TextDocumentItem
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
    private let logger = Logger(subsystem: "com.chimehq.LanguageClient", category: "RestartingServer")

    public var requestHandler: RequestHandler?
    public var notificationHandler: NotificationHandler?
    public var serverProvider: ServerProvider
    public var initializeParamsProvider: InitializeParamsProvider
    public var textDocumentItemProvider: TextDocumentItemProvider
    public var serverCapabilitiesChangedHandler: ServerCapabilitiesChangedHandler?

    public init() {
        self.state = .notStarted
        self.openDocumentURIs = Set()
        self.queue = OperationQueue.serialQueue(named: "com.chimehq.LanguageClient-RestartingServer")

		self.initializeParamsProvider = { throw RestartingServerError.noProvider }
		self.textDocumentItemProvider = { _ in throw RestartingServerError.noProvider }
        self.serverProvider = { throw RestartingServerError.noProvider }
    }

    public func getCapabilities(_ block: @escaping (ServerCapabilities?) -> Void) {
        queue.addOperation {
            switch self.state {
            case .running(let initServer):
				Task {
					let caps = try? await initServer.capabilities

					block(caps)
				}
            case .notStarted, .shuttingDown, .stopped, .restartNeeded:
                block(nil)
            }
        }
    }

	/// Return the capabilities of the server.
	///
	/// This will start the server if it is not running.
	public var capabilities: ServerCapabilities {
		get async throws {
			return try await withCheckedThrowingContinuation { continuation in
				startServerIfNeeded { result in
					switch result {
					case .failure(let error):
						continuation.resume(throwing: error)
					case .success(let server):
						Task {
							let caps = try await server.capabilities
							
							continuation.resume(returning: caps)
						}
					}
				}
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

            op.outputCompletionBlock = block
        }
    }

    private func reopenDocuments(for server: Server, completionHandler: @escaping () -> Void) {
		let openURIs = self.openDocumentURIs

		Task {
			for uri in openURIs {
				self.logger.info("Trying to reopen document \(uri, privacy: .public)")

				do {
					let item = try await textDocumentItemProvider(uri)

					let params = DidOpenTextDocumentParams(textDocument: item)

					try await server.didOpenTextDocument(params: params)
				} catch {
					self.logger.error("Failed to reopen document \(uri, privacy: .public): \(error, privacy: .public)")
				}
			}

			DispatchQueue.global().async {
				completionHandler()
			}
		}
    }

    private func makeNewServer() async throws -> InitializingServer {
        let server = try await serverProvider()

		let handlers = ServerHandlers(requestHandler: { [weak self] in self?.handleRequest($0, completionHandler: $1) },
									  notificationHandler: { [weak self] in self?.handleNotification($0, completionHandler: $1) })

		let config = InitializingServer.Configuration(initializeParamsProvider: { [unowned self] in try await self.initializeParamsProvider() },
													  serverCapabilitiesChangedHandler: { [unowned self] in self.serverCapabilitiesChangedHandler?($0) },
													  handlers: handlers)

        return InitializingServer(server: server, configuration: config)
    }

    private func startNewServer(completionHandler: @escaping (Result<InitializingServer, Error>) -> Void) {
        Task {
            do {
                let server = try await makeNewServer()

                completionHandler(.success(server))
            } catch {
				self.logger.error("Failed to start a new server: \(error, privacy: .public)")

                completionHandler(.failure(error))
            }
        }
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

        op.outputCompletionBlock = block

        queue.addOperation(op)
    }

    public func serverBecameUnavailable() {
		self.logger.info("Server became unavailable")

        let date = Date()

        queue.addOperation {
            if case .stopped = self.state {
				self.logger.info("Server is already stopped")
                return
            }

            self.state = .stopped(date)

            self.queue.addOperation(afterDelay: 5.0) {
                guard case .stopped = self.state else {
					self.logger.info("State change during restart: \(String(describing: self.state), privacy: .public)")
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

    private func handleRequest(_ request: ServerRequest, completionHandler: @escaping (ServerResult<LSPAny>) -> Void) -> Void {
        queue.addOperation {
            guard let handler = self.requestHandler else {
                completionHandler(.failure(.handlerUnavailable(request.method.rawValue)))
                return
            }

            handler(request, completionHandler)
        }
    }
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension RestartingServer: Server {
	public func setHandlers(_ handlers: ServerHandlers, completionHandler: @escaping (ServerError?) -> Void) {
		self.requestHandler = handlers.requestHandler
		self.notificationHandler = handlers.notificationHandler
	}

    public func sendNotification(_ notif: ClientNotification, completionHandler: @escaping (ServerError?) -> Void) {
        startServerIfNeeded { result in
            switch result {
            case .failure(let error):
				self.logger.error("Unable to get server to send notification \(notif.method.rawValue, privacy: .public): \(error, privacy: .public)")

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
				self.logger.error("Unable to get server to send request \(request.method.rawValue, privacy: .public): \(error, privacy: .public)")

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
