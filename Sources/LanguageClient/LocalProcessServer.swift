import Foundation
import LanguageServerProtocol
import JSONRPC

#if os(macOS)

public class LocalProcessServer {
    private let transport: StdioDataTransport
    private let process: Process
    private var wrappedServer: JSONRPCLanguageServer?
    public var terminationHandler: (() -> Void)?

    public convenience init(path: String, arguments: [String], environment: [String : String]? = nil) {
        let params = Process.ExecutionParameters(path: path, arguments: arguments, environment: environment)

        self.init(executionParameters: params)
    }

    public init(executionParameters parameters: Process.ExecutionParameters) {
        self.transport = StdioDataTransport()

        self.wrappedServer = JSONRPCLanguageServer(dataTransport: transport)

        self.process = Process()

        process.standardInput = transport.stdinPipe
        process.standardOutput = transport.stdoutPipe
        process.standardError = transport.stderrPipe

        process.parameters = parameters

        process.terminationHandler = { [unowned self] (task) in
            self.processTerminated(task)
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
        wrappedServer = nil
        terminationHandler?()
    }

    public var logMessages: Bool {
        get { return wrappedServer?.logMessages ?? false }
        set { wrappedServer?.logMessages = newValue }
    }
}

extension LocalProcessServer: LanguageServerProtocol.Server {
    public var requestHandler: RequestHandler? {
        get { return wrappedServer?.requestHandler }
        set { wrappedServer?.requestHandler = newValue }
    }

    public var notificationHandler: NotificationHandler? {
        get { wrappedServer?.notificationHandler }
        set { wrappedServer?.notificationHandler = newValue }
    }

    public func sendNotification(_ notif: ClientNotification, completionHandler: @escaping (ServerError?) -> Void) {
        guard let server = wrappedServer, process.isRunning else {
            completionHandler(.serverUnavailable)
            return
        }

        server.sendNotification(notif, completionHandler: completionHandler)
    }

    public func sendRequest<Response: Codable>(_ request: ClientRequest, completionHandler: @escaping (ServerResult<Response>) -> Void) {
        guard let server = wrappedServer, process.isRunning else {
            completionHandler(.failure(.serverUnavailable))
            return
        }

        server.sendRequest(request, completionHandler: completionHandler)
    }
}

#endif
