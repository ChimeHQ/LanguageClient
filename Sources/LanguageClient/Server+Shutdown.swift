import Foundation

import LanguageServerProtocol

extension Server {
	func simulateShutdown<Response: Decodable>() throws -> Response {
		// We do not want to start up a server here. But, we don't know the
		// genertic type of the return. So, we have to emulate.
		let data = "null".data(using: .utf8)!
		let placeholder = try JSONDecoder().decode(Response.self, from: data)

		return placeholder
	}
}
