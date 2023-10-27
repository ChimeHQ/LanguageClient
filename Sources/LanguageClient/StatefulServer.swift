import Foundation

import LanguageServerProtocol
import LanguageServerProtocol_Client

extension ServerConnection {
	public typealias CapabilitiesSequence = AsyncStream<ServerCapabilities>
}

/// An extension of `Server` that provides access to server state.
protocol StatefulServer: ServerConnection {
	var capabilitiesSequence: ServerConnection.CapabilitiesSequence { get }

	func shutdownAndExit() async throws
	func connectionInvalidated() async
}
