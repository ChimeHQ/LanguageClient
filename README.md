<div align="center">

[![Build Status][build status badge]][build status]
[![Platforms][platforms badge]][platforms]
[![Documentation][documentation badge]][documentation]
[![Discord][discord badge]][discord]

</div>

# LanguageClient

This is a Swift library for abstracting and interacting with language servers that implement the [Language Server Protocol](https://microsoft.github.io/language-server-protocol/). It is built on top of the [LanguageServerProtocol][languageserverprotocol] library.

## General Design

This library is all based around the `ServerConnection` protocol from LanguageServerProtocol. The idea is to wrap up and expose progressively more-complex behavior. This helps to keep things manageable, while also offering lower-complexity types for less-demanding needs. It was also just the first thing I tried that worked out reasonably well.

Because all the types here conform to `ServerConnection`, lots of their functionality is covered by [LanguageServerProtocol][languageserverprotocol]'s documentation. This includes getting access to server events via `eventSequence`.

## Communication

The raw communication between server and client is handled by the `DataChannel` type from the [JSONRPC](https://github.com/ChimeHQ/JSONRPC) package. This package includes two that may already suit your needs:

- `DataChannel.localProcessChannel`: running a server locally on the same machine
- `DataChannel.userScriptDirectory`: uses `NSUserUnixTask` for user application script support to better integrate with sandboxed processes

When making a custom DataChannel, its really important to ensure that all data passes in both directions, including the LSP-specific framing information. The framing looks like HTTP headers, and can seem out of place.

### Environment

Setting correct environment variables is often critical for a language server. An executable on macOS will **not** inherent the user's shell environment. Capturing shell environment variables is tricky business. Despite its name, `ProcessInfo.processInfo.userEnvironment` captures the `process` environment, not the user's.

If you need help here, check out [ProcessEnv](https://github.com/chimehq/processenv).

### Message Ordering

The Language Server protocol is stateful. Some message types are order-dependent. This is something you must be aware of when working with `async` methods. I have found a queue to be essential. Here's [one](https://github.com/mattmassicotte/Queue), if you find yourself looking.

## Usage

### Local Process

This is how you run a local server with not extra functionality. It uses an extension on the [JSONRPC](https://github.com/ChimeHQ/JSONRPC) `DataChannel` type to start up and communicate with a long-running process.

```swift
// Set up parameters to launch the server process
let params = Process.ExecutionParameters(
    path: "/path/to/server-executable",
    arguments: [],
    environment: ProcessInfo.processInfo.userEnvironment
)

// create a DataChannel to handle communication
let channel = try DataChannel.localProcessChannel(
    parameters: params,
    terminationHandler: { print("terminated") }
)

// finally, make a server you can interact with
let server = JSONRPCServerConnection(dataChannel: channel)
```

### InitializingServer

`Server` wrapper that provides automatic initialization. This takes care of the protocol initialization handshake, and does so lazily, on first message.

```swift
import LanguageClient
import LanguageServerProtocol
import Foundation

let executionParams = Process.ExecutionParameters(
    path: "/usr/bin/sourcekit-lsp",
    environment: ProcessInfo.processInfo.userEnvironment
)

let channel = try DataChannel.localProcessChannel(
    parameters: executionParams,
    terminationHandler: { print("terminated") }
)

let localServer = JSONRPCServerConnection(dataChannel: channel)

let docURL = URL(fileURLWithPath: "/path/to/your/test.swift")
let projectURL = docURL.deletingLastPathComponent()

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
                            rootUri: projectURL.path(percentEncoded: false),
                            initializationOptions: nil,
                            capabilities: capabilities,
                            trace: nil,
                            workspaceFolders: nil)
}

let server = InitializingServer(server: localServer, initializeParamsProvider: provider)

Task {
    let docContent = try String(contentsOf: docURL)

    let doc = TextDocumentItem(
        uri: docURL.absoluteString,
        languageId: .swift,
        version: 1,
        text: docContent
    )

    let docParams = DidOpenTextDocumentParams(textDocument: doc)

    try await server.textDocumentDidOpen(params: docParams)

    // make sure to pick a reasonable position within your test document
    let pos = Position(line: 5, character: 25)
    let completionParams = CompletionParams(
        uri: docURL.absoluteString,
        position: pos,
        triggerKind: .invoked,
        triggerCharacter: nil
    )

    let completions = try await server.completion(params: completionParams)

    print("completions: ", completions)
}
```

### RestartingServer

`Server` wrapper that provides transparent server-side state restoration should the underlying process crash. It uses `InitializingServer` internally. Using this type is the most-involved, because it needs to be able to query the current state of the project editor to do its state restoration.

```swift
import LanguageClient
import LanguageServerProtocol
import JSONRPC

typealias MyRestartingServer = RestartingServer<JSONRPCServerConnection>

let executionParams = Process.ExecutionParameters(
    path: "/usr/bin/sourcekit-lsp",
    environment: ProcessInfo.processInfo.userEnvironment
)

let projectURL = URL(fileURLWithPath: "path/to/open/project")

let serverProvider: MyRestartingServer.ServerProvider = {
    let channel = try DataChannel.localProcessChannel(
        parameters: executionParams,
        terminationHandler: { print("terminated") }
    )

    return JSONRPCServerConnection(dataChannel: channel)
}

let openDocumentProvider: MyRestartingServer.TextDocumentItemProvider = { uri in
    // you will have to use the provided uri to look up the actual content of the real document
    return TextDocumentItem(
        uri: uri,
        languageId: "swift",
        version: 1,
        text: "contents of file"
    )
}

let paramProvider: InitializingServer.InitializeParamsProvider = {
    // most of these are placeholders, you will probably need more configuration
    let capabilities = ClientCapabilities(
        workspace: nil,
        textDocument: nil,
        window: nil,
        general: nil,
        experimental: nil
    )

    return InitializeParams(
        processId: Int(ProcessInfo.processInfo.processIdentifier),
        locale: nil,
        rootPath: nil,
        rootUri: projectURL.path(percentEncoded: false),
        initializationOptions: nil,
        capabilities: capabilities,
        trace: nil,
        workspaceFolders: nil
    )
}

let config = MyRestartingServer.Configuration(
    serverProvider: serverProvider,
    textDocumentItemProvider: openDocumentProvider,
    initializeParamsProvider: paramProvider
)

let server = MyRestartingServer(configuration: config)
```

### FileEventAsyncSequence

An `AsyncSequence` that uses FS events and glob patterns to handle `DidChangeWatchedFiles`. It is available only for macOS.


### Responding to Events

You can respond to server events using `eventSequence`. Be careful here as some servers require responses to certain requests. It is also potentially possible that not all request types have been mapped in the ServerRequest type from [LanguageServerProtocol][languageserverprotocol].

```swift
Task {
    for await event in server.eventSequence {
        print("receieved event:", event)
        
        switch event {
        case let .request(id: id, request: request):
            request.relyWithError(MyError.unsupported)
        default:
            print("dropping notification/error")
        }
    }
}
```
## Suggestions or Feedback

We'd love to hear from you! Get in touch via an issue or pull request.

Please note that this project is released with a [Contributor Code of Conduct](CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.

[build status]: https://github.com/ChimeHQ/LanguageClient/actions
[build status badge]: https://github.com/ChimeHQ/LanguageClient/workflows/CI/badge.svg
[platforms]: https://swiftpackageindex.com/ChimeHQ/LanguageClient
[platforms badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FChimeHQ%2FLanguageClient%2Fbadge%3Ftype%3Dplatforms
[documentation]: https://swiftpackageindex.com/ChimeHQ/LanguageClient/main/documentation
[documentation badge]: https://img.shields.io/badge/Documentation-DocC-blue
[discord]: https://discord.gg/esFpX6sErJ
[discord badge]: https://img.shields.io/badge/Discord-purple?logo=Discord&label=Chat&color=%235A64EC

[languageserverprotocol]: https://github.com/ChimeHQ/LanguageServerProtocol
