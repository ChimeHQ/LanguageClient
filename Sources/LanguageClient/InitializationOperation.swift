import Foundation
import OperationPlus
import LanguageServerProtocol

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class InitializationOperation: AsyncProducerOperation<Result<InitializationResponse, Error>> {
    typealias InitializeParamsProvider = InitializingServer.InitializeParamsProvider

    let initializeParamsProvider: InitializeParamsProvider
    let server: Server

    init(server: Server, initializeParamsProvider: @escaping InitializeParamsProvider) {
        self.server = server
        self.initializeParamsProvider = initializeParamsProvider
    }

    override func main() {
		Task {
			do {
				let params = try await initializeParamsProvider()

				let initResponse = try await server.initialize(params: params)

				try await server.initialized(params: InitializedParams())

				self.finish(with: .success(initResponse))
			} catch {
				self.finish(with: .failure(error))
			}
		}
    }
}
