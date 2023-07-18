[![License][license badge]][license]
[![Platforms][platforms badge]][platforms]
[![Documentation][documentation badge]][documentation]

# LanguageClient

This is a Swift library for abstracting and interacting with language servers that implement the [Language Server Protocol](https://microsoft.github.io/language-server-protocol/). It is built on top of the [LanguageServerProtocol](https://github.com/ChimeHQ/LanguageServerProtocol) library.

## General Design

This library is all based around the `Server` protocol from the LanguageServerProtocol library. The idea is to wrap up and expose progressively more-complex behavior. This helps to keep things manageable, while also offering lower-complexity types for less-demanding needs. It was also just the first thing I tried that worked out reasonably well.

## Usage

### Local Process

This is how you run a local server with not extra funtionality. It uses an extension on the [JSONRPC](https://github.com/ChimeHQ/JSONRPC) `DataChannel` type to start up and communicate with a long-running process.

```swift
let params = Process.ExecutionParameters(path: "/path/to/server-executable",
                                         arguments: [],
                                         environment: [])
let channel = DataChannel.localProcessChannel(parameters: params, terminationHandler: { print("terminated") })
let server = JSONRPCServer(dataChannel: channel)
```

### InitializingServer

`Server` wrapper that provides automatic initialization. This takes care of the protocol initialization handshake, and does so lazily, on first message.

```swift
import LanguageClient
import LanguageServerProtocol

let executionParams = Process.ExecutionParameters(path: "/usr/bin/sourcekit-lsp", environment: ProcessInfo.processInfo.userEnvironment)

let channel = DataChannel.localProcessChannel(parameters: executionParams, terminationHandler: { print("terminated") })
let localServer = JSONRPCServer(dataChannel: channel)

let provider: InitializingServer.InitializeParamsProvider = {
    // you may need to fill in more of the textDocument field for completions
    // to work, depending on your server
    let capabilities = ClientCapabilities(workspace: nil,
                                          textDocument: nil,
                                          window: nil,
                                          general: nil,
                                          experimental: nil)
   
    // pay careful attention to rootPath/rootURI/workspaceFolders, as different servers will
    // have different expectations/requirements here
   
    return InitializeParams(processId: Int(ProcessInfo.processInfo.processIdentifier),
                            locale: nil,
                            rootPath: nil,
                            rootURI: projectURL.absoluteString,
                            initializationOptions: nil,
                            capabilities: capabilities,
                            trace: nil,
                            workspaceFolders: nil)
}
let server = InitializingServer(server: localServer, initializeParamsProvider: provider)

let docURL = URL(fileURLWithPath: "/path/to/your/test.swift")
let projectURL = docURL.deletingLastPathComponent()

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

`Server` wrapper that provides transparent server-side state restoration should the underlying process crash. It uses `InitializingServer` internally.

### FileEventAsyncSequence

An `AsyncSequence` that uses FS events and glob patterns to handle `DidChangeWatchedFiles`. It is available only for macOS.

## Environment

Setting correct environment variables can be critical for a language server. An executable on macOS will **not** inherent the user's shell environment. Capturing shell environment variables is tricky business. Despite its name, `ProcessInfo.processInfo.userEnvironment` captures the `process` environment, not the user's.

If you need help here, check out [ProcessEnv](https://github.com/chimehq/processenv) and [ProcessService](https://github.com/chimeHQ/ProcessService).

## Message Ordering

The Language Server protocol is stateful. Some message types are order-dependent. This is something you must be aware of when working with `async` methods. I have found a queue to be essential. Here's [one](https://github.com/mattmassicotte/Queue), if you find yourself looking.

## Suggestions or Feedback

We'd love to hear from you! Get in touch via an issue or pull request.

Please note that this project is released with a [Contributor Code of Conduct](CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.

[license]: https://opensource.org/licenses/BSD-3-Clause
[license badge]: https://img.shields.io/github/license/ChimeHQ/SwiftTreeSitter
[platforms]: https://swiftpackageindex.com/ChimeHQ/LanguageClient
[platforms badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FChimeHQ%2FLanguageClient%2Fbadge%3Ftype%3Dplatforms
[documentation]: https://swiftpackageindex.com/ChimeHQ/LanguageClient/main/documentation
[documentation badge]: https://img.shields.io/badge/Documentation-DocC-blue
