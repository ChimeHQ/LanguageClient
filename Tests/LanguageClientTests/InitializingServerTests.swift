import XCTest
import LanguageServerProtocol
import LanguageClient

// probably should be migrated into LanguageServerProtocol
final class MockServer: Server {
	var responses = [Data]()
	var sentNotifications = [ClientNotification]()
	var sentRequests = [ClientRequest]()

	func setHandlers(_ handlers: LanguageServerProtocol.ServerHandlers, completionHandler: @escaping (ServerError?) -> Void) {
		completionHandler(nil)
	}

	func sendNotification(_ notif: ClientNotification, completionHandler: @escaping (ServerError?) -> Void) {
		sentNotifications.append(notif)

		completionHandler(nil)
	}

	func sendRequest<Response>(_ request: ClientRequest, completionHandler: @escaping (ServerResult<Response>) -> Void) where Response : Decodable, Response : Encodable {
		sentRequests.append(request)

		if responses.isEmpty {
			completionHandler(.failure(.missingExpectedResult))
			return
		}

		let data = responses.removeFirst()

		do {
			let response = try JSONDecoder().decode(Response.self, from: data)

			completionHandler(.success(response))
		} catch {
			completionHandler(.failure(.requestDispatchFailed(error)))
		}
	}
}

extension ClientNotification: Equatable {
	public static func == (lhs: LanguageServerProtocol.ClientNotification, rhs: LanguageServerProtocol.ClientNotification) -> Bool {
		switch (lhs, rhs) {
		case let (.initialized(a), .initialized(b)):
			return a == b
		case (.exit, .exit):
			return true
		case let (.textDocumentDidChange(a), .textDocumentDidChange(b)):
			return a == b
		default:
			return false
		}
	}
}

extension ClientRequest: Equatable {
	public static func == (lhs: LanguageServerProtocol.ClientRequest, rhs: LanguageServerProtocol.ClientRequest) -> Bool {
		switch (lhs, rhs) {
		case let (.initialize(a), .initialize(b)):
			return a == b
		case let (.hover(a), .hover(b)):
			return a == b
		default:
			return false
		}
	}
}

final class InitializingServerTests: XCTestCase {
	func testInitializeOnDemand() async throws {
		let mockServer = MockServer()
		let handlers = ServerHandlers()
		let caps = ClientCapabilities(workspace: nil, textDocument: nil, window: nil, general: nil, experimental: nil)

		let initParams = InitializeParams(processId: 1,
									  locale: nil,
									  rootPath: nil,
									  rootUri: nil,
									  initializationOptions: nil,
									  capabilities: caps,
									  trace: nil,
									  workspaceFolders: nil)

		let config = InitializingServer.Configuration(initializeParamsProvider: {
			return initParams
		}, serverCapabilitiesChangedHandler: nil, handlers: handlers)

		let server = InitializingServer(server: mockServer, configuration: config)

		mockServer.responses = ["""
{"capabilities": {}}
""".data(using: .utf8)!,
								"""
{"contents": "abc", "range": {"start": {"line":0, "character":0}, "end": {"line":0, "character":1}}}
""".data(using: .utf8)!
]
		let params = TextDocumentPositionParams(uri: "abc", position: .init((0, 0)))

		let response = try await server.hover(params: params)

		XCTAssertEqual(mockServer.sentRequests, [
			ClientRequest.initialize(initParams),
			ClientRequest.hover(params),
		])

		XCTAssertEqual(mockServer.sentNotifications, [
			ClientNotification.initialized(InitializedParams())
		])

		XCTAssertEqual(response?.range, LSPRange(startPair: (0, 0), endPair: (0, 1)))
	}

	func testSetHandlers() async throws {
		let mockServer = MockServer()
		let server = InitializingServer(server: mockServer, configuration: .init(initializeParamsProvider: { throw ServerError.missingExpectedParameter }))

		let exp = expectation(description: "called completion")
		Task {
			server.setHandlers(.init()) { error in
				exp.fulfill()
			}
		}

		await fulfillment(of: [exp], timeout: 1.0)
	}
}
