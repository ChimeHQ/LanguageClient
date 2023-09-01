import Foundation

import LanguageServerProtocol
import LanguageServerProtocol_Client

extension Server {
	public typealias CapabilitiesSequence = AsyncStream<ServerCapabilities>
}

/// An extension of `Server` that provides access to server state.
protocol StatefulServer: Server {
	var capabilitiesSequence: Server.CapabilitiesSequence { get }

	func shutdownAndExit() async throws
	func connectionInvalidated() async
}
