import Foundation
import OperationPlus
import LanguageServerProtocol

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
class InitializationOperation: AsyncProducerOperation<Result<InitializationResponse, ServerError>> {
    typealias InitializeParamsProvider = InitializingServer.InitializeParamsProvider

    let initializeParamsProvider: InitializeParamsProvider
    let server: Server

    init(server: Server, initializeParamsProvider: @escaping InitializeParamsProvider) {
        self.server = server
        self.initializeParamsProvider = initializeParamsProvider
    }

    override func main() {
		Task {
			let params = try await initializeParamsProvider()

			let initResponse = try await server.initialize(params: params)

			try await server.initialized(params: InitializedParams())

			self.finish(with: .success(initResponse))
		}

//        getInitializeParams({ (params) in
//            self.server.initialize(params: params) { result in
//                switch result {
//                case .failure(let error):
//                    self.finish(with: .failure(error))
//                case .success(let response):
//                    self.sendInitNotification(response: response)
//                }
//            }
//        })

    }

//    private func getInitializeParams(_ block: @escaping (InitializeParams) -> Void) {
//        initializeParamsProvider({ (result) in
//            switch result {
//            case .failure(let error):
//                self.finish(with: .failure(.clientDataUnavailable(error)))
//            case .success(let params):
//                block(params)
//            }
//        })
//    }
//
//    private func sendInitNotification(response: InitializationResponse) {
//        server.initialized(params: InitializedParams()) { error in
//            if let error = error {
//                self.finish(with: .failure(error))
//                return
//            }
//
//            self.finish(with: .success(response))
//        }
//    }
}
