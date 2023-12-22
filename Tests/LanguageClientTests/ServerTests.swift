import XCTest
import LanguageServerProtocol
import LanguageClient

enum ServerTestError: Error {
	case unsupported
}

#if compiler(>=5.9)
final class ServerTests: XCTestCase {
	typealias Server = RestartingServer<MockServer>

	private static let initParams: InitializeParams = {
		let caps = ClientCapabilities(workspace: nil, textDocument: nil, window: nil, general: nil, experimental: nil)

		return InitializeParams(processId: 1,
								locale: nil,
								rootPath: nil,
								rootUri: nil,
								initializationOptions: nil,
								capabilities: caps,
								trace: nil,
								workspaceFolders: nil)

	}()

	func testInitializeOnDemand() async throws {
		let mockChannel = MockServer()
		let config = Server.Configuration(serverProvider: { mockChannel },
										  textDocumentItemProvider: { _ in throw ServerTestError.unsupported },
										  initializeParamsProvider: { Self.initParams })
		let server = Server(configuration: config)

		await mockChannel.sendMockResponse("""
{"capabilities": {}}
""")
		try await mockChannel.sendMockResponse(Hover(contents: "abc", range: LSPRange(startPair: (0, 0), endPair: (0,1))))

		let params = TextDocumentPositionParams(uri: "abc", position: .init((0, 0)))

		let response = try await server.hover(params)

		let messages = await mockChannel.finishSession()

		XCTAssertEqual(messages, [
			.request(.initialize(Self.initParams, ClientRequest.NullHandler)),
			.notification(.initialized(InitializedParams())),
			.request(.hover(params, ClientRequest.NullHandler)),
		])

		XCTAssertEqual(response?.range, LSPRange(startPair: (0, 0), endPair: (0, 1)))
	}

	func testMonitorsCapabilities() async throws {
		let mockChannel = MockServer()
		let config = Server.Configuration(serverProvider: { mockChannel },
										  textDocumentItemProvider: { _ in throw ServerTestError.unsupported },
										  initializeParamsProvider: { Self.initParams })
		let server = Server(configuration: config)

		await mockChannel.sendMockResponse("""
{"capabilities": {"textDocumentSync": 0}}
""")

		var iterator = server.capabilitiesSequence.makeAsyncIterator()

		_ = try await server.initializeIfNeeded()

		let syncExpected: TwoTypeOption<TextDocumentSyncOptions, TextDocumentSyncKind> = .optionB(.none)
		let caps1 = await iterator.next()

		XCTAssertEqual(caps1?.textDocumentSync, syncExpected)
		XCTAssertNil(caps1?.semanticTokensProvider)

		let options: LSPAny = ["legend": ["tokenTypes": [], "tokenModifiers": []]]

		let params = RegistrationParams(registrations: [
			Registration(id: "abc", method: ClientRequest.Method.textDocumentSemanticTokens.rawValue, registerOptions: options)
		])

		await mockChannel.sendMockRequest(.clientRegisterCapability(params, { _ in }))

		let caps2 = await iterator.next()

		XCTAssertNotNil(caps2?.semanticTokensProvider)
	}
}
#endif
