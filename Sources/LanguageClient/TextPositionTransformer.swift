import Foundation
import SwiftLSPClient
import AppKit

public enum TextPositionTransformerError: Error {
    case invalidRange(LSPRange)
    case invalidLine(Int)
    case invalidLineOffset(Int, Int)
}

public protocol TextPositionTransformer {
    func computePosition(from location: Int) -> Result<Position, Error>
    func computeLocation(from position: Position) -> Result<Int, Error>
}

public extension TextPositionTransformer {
    func computeLSPRange(for range: NSRange) -> Result<LSPRange, Error> {
        let startResult = computePosition(from: range.lowerBound)
        let endResult = computePosition(from: range.upperBound)

        switch (startResult, endResult) {
        case (.success(let start), .success(let end)):
            return .success(LSPRange(start: start, end: end))
        case (.failure(let error), _):
            return .failure(error)
        case (_, .failure(let error)):
            return .failure(error)
        }
    }

    func computeRange(from range: LSPRange) -> Result<NSRange, Error> {
        let startResult = computeLocation(from: range.start)
        let endResult = computeLocation(from: range.end)

        switch (startResult, endResult) {
        case (.success(let start), .success(let end)):
            guard end >= start else {
                return .failure(TextPositionTransformerError.invalidRange(range))
            }

            let length = end - start
            let range = NSRange(location: start, length: length)

            return .success(range)
        case (.failure(let error), _):
            return .failure(error)
        case (_, .failure(let error)):
            return .failure(error)
        }
    }
}

public extension TextPositionTransformer {
    func computeLSPRanges(with ranges: [NSRange]) -> Result<[LSPRange], Error> {
        let results = ranges.map({ computeLSPRange(for: $0) })

        var lspRanges = [LSPRange]()

        for result in results {
            switch result {
            case .failure(let error):
                return .failure(error)
            case .success(let lspRange):
                lspRanges.append(lspRange)
            }
        }

        return .success(lspRanges)
    }
}
