import Foundation
import OperationPlus
import SwiftLSPClient
import LanguageServerProtocol

class InitializationOperation: AsyncProducerOperation<Result<InitializationResponse, ServerError>> {
    typealias StartupState = InitializingServer.StartupState
    typealias StartupStateProvider = InitializingServer.StartupStateProvider

    let startupStateProvider: StartupStateProvider
    let server: Server

    init(server: Server,
         stateProvider: @escaping StartupStateProvider) {
        self.server = server
        self.startupStateProvider = stateProvider
    }

    override func main() {
        getStartupState({ (state) in
            let docs = state.openDocuments
            let params = state.params

            self.server.initialize(params: params) { result in
                switch result {
                case .failure(let error):
                    self.finish(with: .failure(error))
                case .success(let response):
                    self.sendInitNotification(response: response, initialDocs: docs)
                }
            }
        })

    }

    private func getStartupState(_ block: @escaping (StartupState) -> Void) {
        startupStateProvider({ (result) in
            switch result {
            case .failure(let error):
                self.finish(with: .failure(.clientDataUnavailable(error)))
            case .success(let params):
                block(params)
            }
        })
    }

    private func sendInitNotification(response: InitializationResponse, initialDocs: [TextDocumentItem]) {
        server.initialized(params: InitializedParams()) { error in
            if let error = error {
                self.finish(with: .failure(error))
                return
            }

            self.sendDocumentOpenRequests(initialDocs, initResponse: response)
        }
    }

    func sendDocumentOpenRequests(_ items: [TextDocumentItem], initResponse: InitializationResponse) {
        guard let item = items.first else {
            self.finish(with: .success(initResponse))
            return
        }

        let remainingItems = Array(items.dropFirst())

        let params = DidOpenTextDocumentParams(textDocument: item)

        server.didOpenTextDocument(params: params) { error in
            if let error = error {
                self.finish(with: .failure(error))
                return
            }

            // keep going, recursively
            self.sendDocumentOpenRequests(remainingItems, initResponse: initResponse)
        }
    }
}
