import Foundation
#if canImport(os.log)
import os.log
#endif

import LanguageServerProtocol

public enum InitializingServerError: Error {
    case noStateProvider
	case capabilitiesUnavailable
	case stateInvalid
}

public actor InitializingServer {
    public typealias InitializeParamsProvider = () async throws -> InitializeParams
    public typealias ServerCapabilitiesChangedHandler = (ServerCapabilities) -> Void

	public struct Configuration {
		public var initializeParamsProvider: InitializeParamsProvider
		public var serverCapabilitiesChangedHandler: ServerCapabilitiesChangedHandler?
		public var handlers: ServerHandlers

		public init(initializeParamsProvider: @escaping InitializeParamsProvider,
					serverCapabilitiesChangedHandler: ServerCapabilitiesChangedHandler? = nil,
					handlers: ServerHandlers = .init()) {
			self.initializeParamsProvider = initializeParamsProvider
			self.serverCapabilitiesChangedHandler = serverCapabilitiesChangedHandler
			self.handlers = handlers
		}
	}

	enum State {
        case uninitialized
        case initializing(Task<Void, Error>)
        case initialized(ServerCapabilities)
        case shutdown
    }

    private var wrappedServer: Server
    private var state: State
    private var openDocuments: [DocumentUri]
#if canImport(os.log)
	private let log = OSLog(subsystem: "com.chimehq.LanguageClient", category: "InitializingServer")
#endif
	private var configuration: Configuration

	public init(server: Server, configuration: Configuration) {
        self.state = .uninitialized
        self.wrappedServer = server
        self.openDocuments = []

		self.configuration = configuration

		setHandlers(configuration.handlers)
    }

    public func getCapabilities(_ block: @escaping (ServerCapabilities?) -> Void) {
		Task {
			let caps = try? await self.capabilities

			block(caps)
		}
    }

	/// Return the capabilities of the server.
	///
	/// This will not start the server, and will throw if it is not running.
	public var capabilities: ServerCapabilities {
		get async throws {
			switch state {
			case .shutdown, .uninitialized:
				throw InitializingServerError.capabilitiesUnavailable
			case .initialized(let caps):
				return caps
			case .initializing(let task):
				// if we happen to be mid-initialization, wait for that to complete and try again
				try await task.value
			}

			switch state {
			case .shutdown, .uninitialized:
				throw InitializingServerError.capabilitiesUnavailable
			case .initialized(let caps):
				return caps
			case .initializing:
				throw InitializingServerError.stateInvalid
			}
		}
	}
}

extension InitializingServer: Server {
	private func updateConfiguration(_ configuration: Configuration) async {
		let wrappedHandlers = ServerHandlers(requestHandler: { [weak self] in self?.handleRequest($0, completionHandler: $1) },
											 notificationHandler: configuration.handlers.notificationHandler)

		do {
			try await wrappedServer.setHandlers(wrappedHandlers)
		} catch {
#if canImport(os.log)
			os_log("failed to update wrapped handlers: %{public}@", log: self.log, type: .error, String(describing: error))
#else
			print("failed to update wrapped handlers: \(error)")
#endif
		}

		self.configuration = configuration
	}

	public nonisolated func setHandlers(_ handlers: ServerHandlers, completionHandler: @escaping (ServerError?) -> Void) {
		Task {
			var config = await configuration

			config.handlers = handlers

			await self.updateConfiguration(config)

			completionHandler(nil)
		}
	}

    private nonisolated func handleRequest(_ request: ServerRequest, completionHandler: @escaping (ServerResult<LSPAny>) -> Void) -> Void {
		Task {
			do {
				let handler = try await internalHandleRequest(request)

				handler(request, completionHandler)
			} catch {
				if let serverError = error as? ServerError {
					completionHandler(.failure(serverError))
				} else {
					completionHandler(.failure(.requestDispatchFailed(error)))
				}
			}
		}
    }

	private func internalHandleRequest(_ request: ServerRequest) async throws -> Server.RequestHandler {
		guard let handler = self.configuration.handlers.requestHandler else {
			throw ServerError.handlerUnavailable(request.method.rawValue)
		}

		guard case .initialized(let caps) = self.state else {
			assertionFailure("received a request without being initialized")
			throw InitializingServerError.stateInvalid
		}

		var newCaps = caps

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

			self.configuration.serverCapabilitiesChangedHandler?(newCaps)
		}

		return handler
	}

	private func ensureInitialized() async throws {
		switch state {
		case .initialized:
			return
		case .initializing(let task):
			try await task.value
			return
		case .uninitialized, .shutdown:
			break
		}

		let task = Task {
#if canImport(os.log)
			os_log("beginning initialization", log: self.log, type: .info)
#else
			print("beginning initialization")
#endif

			let server = self.wrappedServer

			let params = try await self.configuration.initializeParamsProvider()

			let initResponse = try await server.initialize(params: params)

			try await server.initialized(params: InitializedParams())

			self.state = .initialized(initResponse.capabilities)
		}

		self.state = .initializing(task)

		try await task.value
	}

	private func internalSendNotification(_ notif: ClientNotification) async throws {
		switch (notif, state) {
		case (.exit, .shutdown), (.exit, .uninitialized):
			return
		default:
			break
		}

		try await ensureInitialized()

		try await wrappedServer.sendNotification(notif)
	}

    public nonisolated func sendNotification(_ notif: ClientNotification, completionHandler: @escaping (ServerError?) -> Void) {
		if case .initialized = notif {
			fatalError("Cannot send initialized to InitializingServer")
		}

		Task {
			do {
				try await self.internalSendNotification(notif)

				completionHandler(nil)
			} catch {
				if let serverError = error as? ServerError {
					completionHandler(serverError)
				} else {
					completionHandler(ServerError.notificationDispatchFailed(error))
				}
			}
		}
    }

	private func internalSendRequest<Response: Codable>(_ request: ClientRequest) async throws -> Response {
		switch (request, state) {
		case (.shutdown, .uninitialized), (.shutdown, .shutdown):
			// We do not want to start up a server here
			return try simulateShutdown()
		default:
			break
		}

		try await ensureInitialized()

		let response: Response = try await self.wrappedServer.sendRequest(request)

		if case .shutdown = request {
			self.state = .shutdown
		}

		return response
	}

    public nonisolated func sendRequest<Response>(_ request: ClientRequest, completionHandler: @escaping (ServerResult<Response>) -> Void) where Response : Decodable, Response : Encodable {
		if case .initialize = request {
			fatalError("Cannot initialize to InitializingServer")
		}

		Task {
			do {
				let response: Response = try await internalSendRequest(request)

				completionHandler(.success(response))
			} catch {
				if let serverError = error as? ServerError {
					completionHandler(.failure(serverError))
				} else {
					completionHandler(.failure(.requestDispatchFailed(error)))
				}
			}
		}
    }
}
