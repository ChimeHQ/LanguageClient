import Foundation
#if canImport(os.log)
import os.log
#endif

import Semaphore
import LanguageServerProtocol

enum InitializingServerError: Error {
	case noStateProvider
	case capabilitiesUnavailable
	case stateInvalid
}

/// Server implementation that lazily initializes another Server on first message.
///
/// Provides special handling for `shutdown` and `exit` messages.
///
/// Also exposes an `AsyncSequence` of `ServerCapabilities`, and manages its changes as the server registers and deregisters capabilities.
public actor InitializingServer {
	public typealias InitializeParamsProvider = @Sendable () async throws -> InitializeParams

	private enum State {
		case uninitialized
		case initialized(InitializationResponse)
		case shutdown

		var capabilities: ServerCapabilities? {
			get {
				switch self {
				case .initialized(let initResp):
					return initResp.capabilities
				case .uninitialized, .shutdown:
					return nil
				}
			}
			set {
				guard let caps = newValue else {
					fatalError()
				}

				switch self {
				case .initialized(let initResp):
					self = .initialized(initResp)
				case .uninitialized, .shutdown:
					break
				}
			}
		}

		var serverInfo: ServerInfo? {
			switch self {
			case .initialized(let initResp):
				return initResp.serverInfo
			case .uninitialized, .shutdown:
				return nil
			}
		}
	}

	private let channel: ServerConnection
	private var state = State.uninitialized
	private let semaphore = AsyncSemaphore(value: 1)
	private let eventStreamTap = AsyncStreamTap<ServerEvent>()
	private let initializeParamsProvider: InitializeParamsProvider
	private let capabilitiesContinuation: StatefulServer.CapabilitiesSequence.Continuation

	public let capabilitiesSequence: CapabilitiesSequence

	public init(server: ServerConnection, initializeParamsProvider: @escaping InitializeParamsProvider) {
		self.channel = server
		self.initializeParamsProvider = initializeParamsProvider
		(self.capabilitiesSequence, self.capabilitiesContinuation) = CapabilitiesSequence.makeStream()

		Task {
			await startMonitoringServer()
		}
	}

	deinit {
		capabilitiesContinuation.finish()
	}

	private func startMonitoringServer() async {
		await eventStreamTap.setInputStream(channel.eventSequence) { [weak self] in
			await self?.handleEvent($0)
		}
	}

	/// Return the capabilities of the server.
	///
	/// This will not start the server if it isn't already running.
	public var capabilities: ServerCapabilities? {
		get async {
			do {
				try await semaphore.waitUnlessCancelled()
			} catch {
				return nil
			}

			defer { semaphore.signal() }

			return state.capabilities
		}
	}
		
	/// Return the server's info.
	///
	/// This will not start the server if it isn't already running.
	public var serverInfo: ServerInfo? {
		get async {
			do {
				try await semaphore.waitUnlessCancelled()
			} catch {
				return nil
			}

			defer { semaphore.signal() }

			return state.serverInfo
		}
	}
}

extension InitializingServer: StatefulServer {
	public func shutdownAndExit() async throws {
		await semaphore.wait()
		defer { semaphore.signal() }

		guard case .initialized = state else { return }

		try await channel.shutdown()

		// re-check our state
		guard case .initialized = state else { return }

		self.state = .shutdown

		try await channel.exit()

		// unconditionally set our state after an exit, even though we can assume that connectionInvalidated will be called
		connectionInvalidated()
	}

	public func connectionInvalidated() {
		self.state = .uninitialized
	}

	public nonisolated var eventSequence: EventSequence {
		eventStreamTap.stream
	}

	public func sendNotification(_ notif: LanguageServerProtocol.ClientNotification) async throws {
		switch (notif, state) {
		case (.exit, .shutdown), (.exit, .uninitialized):
			return
		default:
			break
		}

		_ = try await initializeIfNeeded()

		try await channel.sendNotification(notif)
	}

	public func sendRequest<Response>(_ request: LanguageServerProtocol.ClientRequest) async throws -> Response where Response : Decodable, Response : Sendable {
		if case .initialize = request {
			fatalError("Cannot initialize to InitializingServer")
		}

		switch (request, state) {
		case (.shutdown, .uninitialized), (.shutdown, .shutdown):
			// We do not want to start up a server here
			return try simulateShutdown()
		default:
			break
		}

		_ = try await initializeIfNeeded()

		return try await channel.sendRequest(request)
	}
}

extension InitializingServer {
	/// Run the initialization sequence with the server, if it has not already happened.
	public func initializeIfNeeded() async throws -> InitializationResponse {
		switch state {
		case .initialized(let initResp):
			return initResp
		case .uninitialized, .shutdown:
			try await semaphore.waitUnlessCancelled()
		}

		defer { semaphore.signal() }

		let params = try await initializeParamsProvider()
		let initResponse = try await channel.initialize(params)

		try await channel.initialized(InitializedParams())
		self.state = .initialized(initResponse)

		capabilitiesContinuation.yield(initResponse.capabilities)

		return initResponse
	}

	private func handleEvent(_ event: ServerEvent) {
		switch event {
		case let .request(_, request):
			handleRequest(request)
		default:
			break
		}
	}

	private func handleRequest(_ request: ServerRequest) {
		guard case .initialized(let initResp) = self.state else {
			fatalError("received a request without being initialized")
		}

		var newCaps = initResp.capabilities

		do {
			switch request {
			case .clientRegisterCapability(let params, _):
				try newCaps.applyRegistrations(params.registrations)
			case .clientUnregisterCapability(let params, _):
				try newCaps.applyUnregistrations(params.unregistrations)
			default:
				break
			}
		} catch {
			print("unable to mutate server capabilities: \(error)")
		}

		if initResp.capabilities != newCaps {
			self.state = .initialized(InitializationResponse(capabilities: newCaps, serverInfo: initResp.serverInfo))
			capabilitiesContinuation.yield(newCaps)
		}
	}
}
