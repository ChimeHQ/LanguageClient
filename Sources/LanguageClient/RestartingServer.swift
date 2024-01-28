import Foundation
#if canImport(OSLog)
import OSLog
#endif

#if !(os(macOS) || os(iOS) || os(tvOS))
/* nanoseconds per second */
let NSEC_PER_SEC: UInt64 = 1000000000
#endif

import Semaphore
import LanguageServerProtocol

public enum RestartingServerError: Error {
	case noProvider
	case serverStopped
	case noURIMatch(DocumentUri)
	case noTextDocumentForURI(DocumentUri)
}

/// A `Server` wrapper that provides transparent server-side state restoration should the underlying process crash.
public actor RestartingServer<WrappedServer: ServerConnection & Sendable> {
	public typealias ServerProvider = @Sendable () async throws -> WrappedServer
	public typealias TextDocumentItemProvider = @Sendable (DocumentUri) async throws -> TextDocumentItem
	public typealias InitializeParamsProvider = InitializingServer.InitializeParamsProvider

	public struct Configuration: Sendable {
		public var serverProvider: ServerProvider
		public var initializeParamsProvider: InitializeParamsProvider
		public var textDocumentItemProvider: TextDocumentItemProvider

		public init(serverProvider: @escaping ServerProvider,
					textDocumentItemProvider: @escaping TextDocumentItemProvider,
					initializeParamsProvider: @escaping InitializeParamsProvider) {
			self.serverProvider = serverProvider
			self.textDocumentItemProvider = textDocumentItemProvider
			self.initializeParamsProvider = initializeParamsProvider
		}
	}

	private enum State {
		case notStarted
		case restartNeeded
		case running(InitializingServer)
		case shuttingDown
		case stopped(Date)

		var isRunning: Bool {
			if case .running = self {
				return true
			}

			return false
		}
	}

	private let semaphore = AsyncSemaphore(value: 1)
	private var state: State
	private var openDocumentURIs: Set<DocumentUri>
	private let configuration: Configuration
#if canImport(OSLog)
	private let logger = Logger(subsystem: "com.chimehq.LanguageClient", category: "RestartingServer")
#endif

	private let eventStreamTap = AsyncStreamTap<ServerEvent>()
	private let capabilitiesStreamTap = AsyncStreamTap<ServerCapabilities>()

	public init(configuration: Configuration) {
		self.state = .notStarted
		self.openDocumentURIs = Set()
		self.configuration = configuration
	}

	/// Return the capabilities of the server.
	///
	/// This will not start the server if it isn't already running.
	public var capabilities: ServerCapabilities? {
		get async {
			switch state {
			case .running(let server):
				return await server.capabilities
			case .notStarted, .shuttingDown, .stopped, .restartNeeded:
				return nil
			}
		}
	}

	public func shutdownAndExit() async throws {
		await semaphore.wait()
		defer { semaphore.signal() }

		switch state {
		case .notStarted, .shuttingDown, .stopped, .restartNeeded:
			return
		case .running(let server):
#if canImport(OSLog)
			logger.debug("shutting down")
#endif

			self.state = .shuttingDown

			try await server.shutdownAndExit()

#if canImport(os.log)
			logger.info("shutdown and exit complete")
#endif
			self.state = .notStarted
		}
	}

	/// Run the initialization sequence with the server, if it has not already happened.
	public func initializeIfNeeded() async throws -> InitializationResponse {
		try await startServerIfNeeded().initializeIfNeeded()
	}

	private func reopenDocuments(for server: InitializingServer) async {
		let openURIs = self.openDocumentURIs

		for uri in openURIs {
#if canImport(OSLog)
			logger.info("Trying to reopen document \(uri, privacy: .public)")
#endif

			do {
				let item = try await configuration.textDocumentItemProvider(uri)

				let params = DidOpenTextDocumentParams(textDocument: item)

				try await server.textDocumentDidOpen(params)
			} catch {
#if canImport(OSLog)
				logger.error("Failed to reopen document \(uri, privacy: .public): \(error, privacy: .public)")
#else
				print("Failed to reopen document: \(uri), \(error)")
#endif
			}
		}
	}

	private func startMonitoringServer(_ server: InitializingServer) async {
		await eventStreamTap.setInputStream(server.eventSequence)
		await capabilitiesStreamTap.setInputStream(server.capabilitiesSequence)
	}

	private func makeNewServer() async throws -> InitializingServer {
#if canImport(os.log)
		logger.info("creating server")
#endif

		let server = try await configuration.serverProvider()
		let provider = configuration.initializeParamsProvider

		// I believe the Sendability warning about `server` here is incorrect (this has been confirmed as a compiler bug)
		return InitializingServer(server: server, initializeParamsProvider: provider)
	}

	private func startServerIfNeeded() async throws -> InitializingServer {
		await semaphore.wait()
		defer { semaphore.signal() }

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
		await startMonitoringServer(server)

		if reopenDocs {
			await reopenDocuments(for: server)
		}

		return server
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
		case .textDocumentDidOpen(let params):
			self.handleDidOpen(params)
		case .textDocumentDidClose(let params):
			self.handleDidClose(params)
		default:
			break
		}
	}
}

extension RestartingServer: StatefulServer {
	public func connectionInvalidated() async {
#if canImport(OSLog)
		logger.info("Server became unavailable")
#endif

		let date = Date()

		if case .stopped = self.state {
#if canImport(OSLog)
			logger.info("Server is already stopped")
#endif
			return
		}

		self.state = .stopped(date)

		// this sleep is here just to throttle rate of restarting
		try? await Task.sleep(nanoseconds: 5 * NSEC_PER_SEC)

		guard case .stopped = self.state else {
#if canImport(OSLog)
			logger.warning("State change during restart: \(String(describing: self.state), privacy: .public)")
#endif
			return
		}

		self.state = .notStarted
	}

	public nonisolated var eventSequence: EventSequence {
		eventStreamTap.stream
	}

	public nonisolated var capabilitiesSequence: CapabilitiesSequence {
		capabilitiesStreamTap.stream
	}

	public func sendNotification(_ notif: ClientNotification) async throws {
		if case .exit = notif, state.isRunning == false {
			// do not attempt to relay exit to servers that aren't running
			return
		}

		let server = try await startServerIfNeeded()

		processOutboundNotification(notif)

		try await server.sendNotification(notif)
	}

	public func sendRequest<Response>(_ request: ClientRequest) async throws -> Response where Response : Decodable, Response : Sendable {
		if case .shutdown = request, state.isRunning == false {
			return try simulateShutdown()
		}

		let server = try await startServerIfNeeded()

		return try await server.sendRequest(request)
	}
}
