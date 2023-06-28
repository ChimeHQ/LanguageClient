import Foundation
import LanguageServerProtocol
import JSONRPC

#if canImport(ProcessEnv)
import ProcessEnv

enum LocalProcessServerError: Error {
	case processUnavailable
}

extension DataChannel {
	public static func localProcessChannel(parameters: Process.ExecutionParameters) throws -> DataChannel {
		let process = Process()
		let transport = StdioDataTransport()
		let dataChannel = DataChannel.transportChannel(with: transport)

		process.standardInput = transport.stdinPipe
		process.standardOutput = transport.stdoutPipe
		process.standardError = transport.stderrPipe

		process.parameters = parameters

		let (stream, continuation) = DataSequence.makeStream()

		process.terminationHandler = { _ in
			continuation.finish()
		}

		Task {
			for await data in dataChannel.dataSequence {
				continuation.yield(data)
			}
		}

		try process.run()

		let handler: DataChannel.WriteHandler = {
			// this is wacky, but we need the channel to hold a strong reference to the process
			// to prevent it from being deallocated
			_ = process

			try await dataChannel.writeHandler($0)
		}

		return DataChannel(writeHandler: handler, dataSequence: stream)
	}
}

/// Manages a commiunications channel for a locally-running language server process.
public actor LocalProcessServer {
	public typealias TerminationHandler = @Sendable () -> Void

    private let transport = StdioDataTransport()
    private let process = Process()
    private var channel: JSONRPCServer?
	private let notificationStreamTap = AsyncStreamTap<ServerNotification>()
	private let requestStreamTap = AsyncStreamTap<ServerRequest>()

	private let terminationHandler: TerminationHandler

	public init(path: String, arguments: [String], environment: [String : String]? = nil, terminationHandler: @escaping TerminationHandler = {}) {
        let params = Process.ExecutionParameters(path: path, arguments: arguments, environment: environment)

        self.init(executionParameters: params, terminationHandler: terminationHandler)
    }

	public init(executionParameters parameters: Process.ExecutionParameters, terminationHandler: @escaping TerminationHandler = {}) {
		self.terminationHandler = terminationHandler

		let dataChannel = DataChannel.transportChannel(with: transport)

		self.channel = JSONRPCServer(dataChannel: dataChannel)

		Task {
			await startMonitoringServer()
		}

        process.standardInput = transport.stdinPipe
        process.standardOutput = transport.stdoutPipe
        process.standardError = transport.stderrPipe

        process.parameters = parameters

        process.terminationHandler = { [unowned self] (task) in
			Task {
				await processTerminated(task)
			}
        }

        process.launch()
    }

    deinit {
        process.terminationHandler = nil
        process.terminate()
        transport.close()
    }

    private func processTerminated(_ process: Process) {
        transport.close()

        // releasing the server here will short-circuit any pending requests,
        // which might otherwise take a while to time out, if ever.
        channel = nil
		terminationHandler()
    }

	private func startMonitoringServer() async {
		guard let channel = channel else { return }

		await notificationStreamTap.setInputStream(channel.notificationSequence)
		await requestStreamTap.setInputStream(channel.requestSequence)
	}
	
//    public var logMessages: Bool {
//        get { return wrappedServer?.logMessages ?? false }
//		set { wrappedServer?.logMessages = newValue }
//    }
}

extension LocalProcessServer: Server {
	public nonisolated var notificationSequence: NotificationSequence {
		notificationStreamTap.stream
	}

	public nonisolated var requestSequence: RequestSequence {
		requestStreamTap.stream
	}

	public func sendNotification(_ notif: ClientNotification) async throws {
		guard let channel = channel, process.isRunning else {
			throw LocalProcessServerError.processUnavailable
		}

		try await channel.sendNotification(notif)
	}

	public func sendRequest<Response>(_ request: ClientRequest) async throws -> Response where Response : Decodable, Response : Sendable {
		guard let channel = channel, process.isRunning else {
			throw LocalProcessServerError.processUnavailable
		}

		return try await channel.sendRequest(request)
	}
}

#endif
