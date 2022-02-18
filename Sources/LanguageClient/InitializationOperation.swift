import Foundation
import OperationPlus
import LanguageServerProtocol

class InitializationOperation: AsyncProducerOperation<Result<InitializationResponse, ServerError>> {
    typealias InitializeParamsProvider = InitializingServer.InitializeParamsProvider

    let initializeParamsProvider: InitializeParamsProvider
    let server: Server

    init(server: Server, initializeParamsProvider: @escaping InitializeParamsProvider) {
        self.server = server
        self.initializeParamsProvider = initializeParamsProvider
    }

    override func main() {
        getInitializeParams({ (params) in
            self.server.initialize(params: params) { result in
                switch result {
                case .failure(let error):
                    self.finish(with: .failure(error))
                case .success(let response):
                    self.sendInitNotification(response: response)
                }
            }
        })

    }

    private func getInitializeParams(_ block: @escaping (InitializeParams) -> Void) {
        initializeParamsProvider({ (result) in
            switch result {
            case .failure(let error):
                self.finish(with: .failure(.clientDataUnavailable(error)))
            case .success(let params):
                block(params)
            }
        })
    }

    private func sendInitNotification(response: InitializationResponse) {
        server.initialized(params: InitializedParams()) { error in
            if let error = error {
                self.finish(with: .failure(error))
                return
            }

            self.finish(with: .success(response))
        }
    }
}
