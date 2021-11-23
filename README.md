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

### InitializingServer

`Server` wrapper that provides automatic initialization.

### RestartingServer

`Server` wrapper that provides both transparent server-side state restoration should the underlying process crash.

### TextPositionTransformer

A protocol useful for translating between `NSRange` and LSP's line-relative positioning system.

## Suggestions or Feedback

We'd love to hear from you! Get in touch via [twitter](https://twitter.com/chimehq), an issue, or a pull request.

Please note that this project is released with a [Contributor Code of Conduct](CODE_OF_CONDUCT.md). By participating in this project you agree to abide by its terms.
