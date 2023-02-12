import Foundation
import os.log

import JSONRPC
import LanguageServerProtocol

public enum RestartingServerError: Error {
    case noProvider
    case serverStopped
    case noURIMatch(DocumentUri)
    case noTextDocumentForURI(DocumentUri)
}

/// A `Server` wrapper that provides both transparent server-side state restoration should the underlying process crash.
@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
public actor RestartingServer {
    public typealias ServerProvider = () async throws -> Server
    public typealias TextDocumentItemProvider = (DocumentUri) async throws -> TextDocumentItem
    public typealias InitializeParamsProvider = InitializingServer.InitializeParamsProvider
    public typealias ServerCapabilitiesChangedHandler = InitializingServer.ServerCapabilitiesChangedHandler

	public struct Configuration {
		public var serverProvider: ServerProvider
		public var initializeParamsProvider: InitializeParamsProvider
		public var serverCapabilitiesChangedHandler: ServerCapabilitiesChangedHandler?
		public var textDocumentItemProvider: TextDocumentItemProvider
		public var handlers: ServerHandlers

		public init(serverProvider: @escaping ServerProvider,
					textDocumentItemProvider: @escaping TextDocumentItemProvider,
					initializeParamsProvider: @escaping InitializeParamsProvider,
					serverCapabilitiesChangedHandler: ServerCapabilitiesChangedHandler? = nil,
					handlers: ServerHandlers = .init()) {
			self.serverProvider = serverProvider
			self.textDocumentItemProvider = textDocumentItemProvider
			self.initializeParamsProvider = initializeParamsProvider
			self.serverCapabilitiesChangedHandler = serverCapabilitiesChangedHandler
			self.handlers = handlers
		}
	}

    enum State {
        case notStarted
        case restartNeeded
        case running(InitializingServer)
        case shuttingDown
        case stopped(Date)
    }

    private var state: State
    private var openDocumentURIs: Set<DocumentUri>
    private let logger = Logger(subsystem: "com.chimehq.LanguageClient", category: "RestartingServer")
	private var configuration: Configuration

    public init(configuration: Configuration) {
        self.state = .notStarted
        self.openDocumentURIs = Set()
		self.configuration = configuration
    }

    public func getCapabilities(_ block: @escaping (ServerCapabilities?) -> Void) {
		Task {
			switch self.state {
			case .running(let initServer):
				let caps = try? await initServer.capabilities

				block(caps)
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
			return try await startServerIfNeeded().capabilities
		}
	}

    public func shutdownAndExit(block: @escaping (ServerError?) -> Void) {
		Task {
			do {
				try await shutdownAndExit()

				block(nil)
			} catch let error as ServerError {
				block(error)
			} catch {
				block(ServerError.unableToSendRequest(error))
			}
		}
    }

	public func shutdownAndExit() async throws {
		guard case .running(let server) = self.state else {
			throw ServerError.serverUnavailable
		}

		try await server.shutdown()
		try await server.exit()
	}

    private func reopenDocuments(for server: Server) async {
		let openURIs = self.openDocumentURIs

		for uri in openURIs {
			self.logger.info("Trying to reopen document \(uri, privacy: .public)")

			do {
				let item = try await configuration.textDocumentItemProvider(uri)

				let params = DidOpenTextDocumentParams(textDocument: item)

				try await server.didOpenTextDocument(params: params)
			} catch {
				self.logger.error("Failed to reopen document \(uri, privacy: .public): \(error, privacy: .public)")
			}
		}
    }

    private func makeNewServer() async throws -> InitializingServer {
		let server = try await configuration.serverProvider()

		let config = InitializingServer.Configuration(initializeParamsProvider: configuration.initializeParamsProvider,
													  serverCapabilitiesChangedHandler: configuration.serverCapabilitiesChangedHandler,
													  handlers: configuration.handlers)

        return InitializingServer(server: server, configuration: config)
    }

	private func startServerIfNeeded() async throws -> InitializingServer {
		switch self.state {
		case .notStarted:
			return try await startNewServerAndAdjustState(reopenDocs: false)
		case .restartNeeded:
			return try await startNewServerAndAdjustState(reopenDocs: true)
		case .running(let server):
			return server
		case .stopped, .shuttingDown:
			throw RestartingServerError.serverStopped
		}
	}

    private func startNewServerAndAdjustState(reopenDocs: Bool) async throws -> InitializingServer {
		let server = try await makeNewServer()

        self.state = .running(server)

		if reopenDocs {
			await reopenDocuments(for: server)
		}

		return server
    }

    public nonisolated func serverBecameUnavailable() {
		Task {
			await handleServerBecameUnavailable()
		}
    }

	private func handleServerBecameUnavailable() async {
		self.logger.info("Server became unavailable")

		let date = Date()

		if case .stopped = self.state {
			self.logger.info("Server is already stopped")
			return
		}

		self.state = .stopped(date)

		// this sleep is here just to throttle rate of restarting
		try? await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)

		guard case .stopped = self.state else {
			self.logger.info("State change during restart: \(String(describing: self.state), privacy: .public)")
			return
		}

		self.state = .notStarted
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
}

@available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
extension RestartingServer: Server {
	private func updateConfiguration(_ handlers: ServerHandlers) async throws {
		self.configuration.handlers = handlers

		switch state {
		case .running(let server):
			try await server.setHandlers(handlers)
		case .notStarted, .restartNeeded, .shuttingDown, .stopped:
			break
		}
	}

	public nonisolated func setHandlers(_ handlers: ServerHandlers, completionHandler: @escaping (ServerError?) -> Void) {
		Task {
			do {
				try await updateConfiguration(handlers)

				completionHandler(nil)
			} catch let error as ServerError {
				completionHandler(error)
			} catch {
				completionHandler(ServerError.unableToSendRequest(error))
			}
		}
	}

	private func internalSendNotification(_ notif: ClientNotification) async throws {
		let server = try await startServerIfNeeded()

		processOutboundNotification(notif)

		do {
			try await server.sendNotification(notif)
		} catch ServerError.serverUnavailable {
			await handleServerBecameUnavailable()
			throw ServerError.serverUnavailable
		}
	}

    public nonisolated func sendNotification(_ notif: ClientNotification, completionHandler: @escaping (ServerError?) -> Void) {
		Task {
			do {
				try await internalSendNotification(notif)

				completionHandler(nil)
			} catch let error as ServerError {
				self.logger.error("Unable to get server to send notification \(notif.method.rawValue, privacy: .public): \(error, privacy: .public)")

				completionHandler(error)
			} catch {
				self.logger.error("Unable to get server to send notification \(notif.method.rawValue, privacy: .public): \(error, privacy: .public)")

				completionHandler(ServerError.notificationDispatchFailed(error))
			}
		}
    }

	private func internalSendRequest<Response: Codable>(_ request: ClientRequest) async throws -> Response {
		let server = try await startServerIfNeeded()

		do {
			return try await server.sendRequest(request)
		} catch ServerError.serverUnavailable {
			await handleServerBecameUnavailable()
			throw ServerError.serverUnavailable
		}
	}

    public nonisolated func sendRequest<Response: Codable>(_ request: ClientRequest, completionHandler: @escaping (ServerResult<Response>) -> Void) {
		Task {
			do {
				let response: Response = try await internalSendRequest(request)

				completionHandler(.success(response))
			} catch let error as ServerError {
				self.logger.error("Unable to get server to send request \(request.method.rawValue, privacy: .public): \(error, privacy: .public)")

				completionHandler(.failure(error))
			} catch {
				self.logger.error("Unable to get server to send request \(request.method.rawValue, privacy: .public): \(error, privacy: .public)")

				completionHandler(.failure(.unableToSendRequest(error)))
			}
		}
    }
}
