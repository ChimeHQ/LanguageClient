# LanguageClient

This is a Swift library for abstracting and interacting with language servers that implement the [Language Server Protocol](https://microsoft.github.io/language-server-protocol/). It is built on top of the [LanguageServerProtocol](https://github.com/ChimeHQ/LanguageServerProtocol) library.

## Integration

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/ChimeHQ/LanguageClient")
]
```

## Classes

### LocalProcessServer

This class manages a locally-running LSP process.

```swift
let params = Process.ExecutionParameters(path: "/path/to/server-executable",
                                         arguments: [],
                                         environment: [])
let processServer = LocalProcessServer(executionParameters: params)
processServer.terminationHandler = { print("server exited") }

// and if you want to observe communications
processServer.logMessages = true
```

Setting correct environment variables could be critical for your server. Your program may not have the same environment as your shell. Capturing shell environment variables is tricky business. If you need help here, check out [ProcessEnv](https://github.com/chimehq/processenv).

### InitializingServer

`Server` wrapper that provides automatic initialization. This takes care of the protocol initialization handshake, and does so lazily, on first message.

```swift
import LanguageClient
import LanguageServerProtocol

let executionParams = Process.ExecutionParameters(path: "/usr/bin/sourcekit-lsp")

let localServer = LocalProcessServer(executionParameters: executionParams)

let server = InitializingServer(server: localServer)

let docURL = URL(fileURLWithPath: "/path/to/your/test.swift")
let projectURL = docURL.deletingLastPathComponent()

server.initializeParamsProvider = {
    // you may need to fill more of the textDocument field in for completions
    // to work, depending on your server
    let capabilities = ClientCapabilities(workspace: nil,
                                          textDocument: nil,
                                          window: nil,
                                          general: nil,
                                          experimental: nil)

    // pay careful attention to rootPath/rootURI/workspaceFolders, as different servers will
    // have different expectations/requirements here

    return InitializeParams(processId: Int(ProcessInfo.processInfo.processIdentifier),
                            rootPath: nil,
                            rootURI: projectURL.absoluteString,
                            initializationOptions: nil,
                            capabilities: capabilities,
                            trace: nil,
                            workspaceFolders: nil)
}

Task {
    let docContent = try String(contentsOf: docURL)

    let doc = TextDocumentItem(uri: docURL.absoluteString,
                               languageId: .swift,
                               version: 1,
                               text: docContent)
    let docParams = DidOpenTextDocumentParams(textDocument: doc)

    try await server.didOpenTextDocument(params: docParams)

    // make sure to pick a reasonable position within your test document
    let pos = Position(line: 5, character: 25)
    let completionParams = CompletionParams(uri: docURL.absoluteString,
                                            position: pos,
                                            triggerKind: .invoked,
                                            triggerCharacter: nil)
    let completions = try await server.completion(params: completionParams)

    print("completions: ", completions)
}
```

### RestartingServer

`Server` wrapper that provides both transparent server-side state restoration should the underlying process crash.

### TextPositionTransformer

A protocol useful for translating between `NSRange` and LSP's line-relative positioning system.

### FileWatcher

A utility class that uses FS events and glob patterns to handle `DidChangeWatchedFiles`.

## Suggestions or Feedback

We'd love to hear from you! Get in touch via [twitter](https://twitter.com/chimehq), an issue, or a pull request.

Please note that this project is released with a [Contributor Code of Conduct](CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.
