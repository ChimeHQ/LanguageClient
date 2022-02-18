import Foundation
import OperationPlus
import LanguageServerProtocol

class ShutdownOperation: AsyncProducerOperation<ServerError?> {
    let server: Server

    init(server: Server) {
        self.server = server
    }

    override func main() {
        server.shutdown { shudownError in
            if let error = shudownError {
                self.finish(with: error)
                return
            }

            self.server.exit { exitError in
                self.finish(with: exitError)
            }
        }
    }
}
