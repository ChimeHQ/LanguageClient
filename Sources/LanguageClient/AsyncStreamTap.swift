import Foundation

#if compiler(>=5.9)
/// Maintains a consistent external `AsyncStream` as interal source streams are changed.
public actor AsyncStreamTap<Element: Sendable> {
	public typealias Stream = AsyncStream<Element>
	public typealias Action = @Sendable (Element) async -> Void

	private let continuation: Stream.Continuation
	public nonisolated let stream: Stream
	private var task: Task<Void, Never>?

	public init() {
		(self.stream, self.continuation) = Stream.makeStream()
	}

	deinit {
		continuation.finish()
		task?.cancel()
	}

	public func setInputStream(_ input: Stream, action: @escaping Action = { _ in }) {
		task?.cancel()
		self.task = Task { [continuation] in
			for await value in input {
				await action(value)

				continuation.yield(value)
			}
		}
	}
}
#endif
