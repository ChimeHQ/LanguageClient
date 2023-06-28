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

#if compiler(>=5.9)
/// Server implementation that lazily initializes another Server on first message.
///
/// Provides special handling for `shutdown` and `exit` messages.
///
/// Also exposes an `AsyncSequence` of `ServerCapabilities`, and manages its changes as the server registers and deregisters capabilities.
public actor InitializingServer {
	public typealias InitializeParamsProvider = @Sendable () async throws -> InitializeParams

	private enum State {
		case uninitialized
		case initialized(ServerCapabilities)
		case shutdown

		var capabilities: ServerCapabilities? {
			get {
				switch self {
				case .initialized(let capabilities):
					return capabilities
				case .uninitialized, .shutdown:
					return nil
				}
			}
			set {
				guard let caps = newValue else {
					fatalError()
				}

				switch self {
				case .initialized:
					self = .initialized(caps)
				case .uninitialized, .shutdown:
					break
				}
			}
		}
	}

	private let channel: Server
	private var state = State.uninitialized
	private let semaphore = AsyncSemaphore(value: 1)
	private let requestStreamTap = AsyncStreamTap<ServerRequest>()
	private let initializeParamsProvider: InitializeParamsProvider
	private let capabilitiesContinuation: StatefulServer.CapabilitiesSequence.Continuation

	public let notificationSequence: NotificationSequence
	public let capabilitiesSequence: CapabilitiesSequence

	public init(server: Server, initializeParamsProvider: @escaping InitializeParamsProvider) {
		self.channel = server
		self.initializeParamsProvider = initializeParamsProvider
		self.notificationSequence = channel.notificationSequence
		(self.capabilitiesSequence, self.capabilitiesContinuation) = CapabilitiesSequence.makeStream()

		Task {
			await startMonitoringServer()
		}
	}

	deinit {
		capabilitiesContinuation.finish()
	}

	private func startMonitoringServer() async {
		await requestStreamTap.setInputStream(channel.requestSequence) { [weak self] in
			await self?.handleRequest($0)
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

	public nonisolated var requestSequence: RequestSequence {
		requestStreamTap.stream
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
	public func initializeIfNeeded() async throws -> ServerCapabilities {
		switch state {
		case .initialized(let caps):
			return caps
		case .uninitialized, .shutdown:
			try await semaphore.waitUnlessCancelled()
		}

		defer { semaphore.signal() }

		let params = try await initializeParamsProvider()

		let initResponse = try await channel.initialize(params: params)
		let caps = initResponse.capabilities

		try await channel.initialized(params: InitializedParams())

		self.state = .initialized(caps)

		capabilitiesContinuation.yield(caps)

		return caps
	}

	private func handleRequest(_ request: ServerRequest) {
		guard case .initialized(let caps) = self.state else {
			fatalError("received a request without being initialized")
		}

		var newCaps = caps

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

		if caps != newCaps {
			self.state = .initialized(newCaps)

			capabilitiesContinuation.yield(newCaps)
		}
	}
}
#endif
