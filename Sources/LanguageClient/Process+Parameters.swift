import Foundation

#if os(macOS)

public extension Process {
    struct ExecutionParameters {
        public var path: String
        public var arguments: [String]
        public var environment: [String : String]?
        public var currentDirectoryURL: URL?

        public init(path: String, arguments: [String] = [], environment: [String : String]? = nil, currentDirectoryURL: URL? = nil) {
            self.path = path
            self.arguments = arguments
            self.environment = environment
            self.currentDirectoryURL = currentDirectoryURL
        }
    }

    var parameters: ExecutionParameters {
        get {
            return ExecutionParameters(path: self.launchPath ?? "",
                                       arguments: arguments ?? [],
                                       environment: self.environment,
                                       currentDirectoryURL: self.currentDirectoryURL)
        }
        set {
            self.launchPath = newValue.path
            self.arguments = newValue.arguments
            self.environment = newValue.environment
            self.currentDirectoryURL = newValue.currentDirectoryURL
        }
    }
}

#endif
