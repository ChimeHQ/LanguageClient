import Foundation

public extension Process {
    struct ExecutionParameters {
        public var path: String
        public var arguments: [String]
        public var environment: [String : String]?

        public init(path: String, arguments: [String] = [], environment: [String : String]? = nil) {
            self.path = path
            self.arguments = arguments
            self.environment = environment
        }
    }

    var parameters: ExecutionParameters {
        get {
            return ExecutionParameters(path: self.launchPath ?? "",
                                       arguments: arguments ?? [],
                                       environment: self.environment)
        }
        set {
            self.launchPath = newValue.path
            self.arguments = newValue.arguments
            self.environment = newValue.environment
        }
    }
}
