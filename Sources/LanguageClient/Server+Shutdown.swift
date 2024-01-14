import Foundation

import LanguageServerProtocol

extension ServerConnection {
	/// This function will always attempt to decode "null".
	///
	/// We don't know the generic type of the return. So, we have to emulate.
	func simulateShutdown<Response: Decodable>() throws -> Response {
		let data = "null".data(using: .utf8)!
		return try JSONDecoder().decode(Response.self, from: data)
	}
}
