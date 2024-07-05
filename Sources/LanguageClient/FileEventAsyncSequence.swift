import Foundation
import LanguageServerProtocol

#if canImport(FSEventsWrapper)
import FSEventsWrapper
import Glob

extension FSEvent {
	var pathTypePair: (String, FileChangeType)? {
		switch self {
		case .generic(let path, _, _):
			return (path, .changed)
		case .mustScanSubDirs(let path, _):
			// I think this is probably insufficient
			return (path, .changed)
		case .eventIdsWrapped:
			break
		case .streamHistoryDone:
			break
		case .rootChanged(let path, _):
			return (path, .changed)
		case .volumeMounted(let path, _, _):
			return (path, .changed)
		case .volumeUnmounted(let path, _, _):
			return (path, .deleted)
		case .itemCreated(let path, _, _, _):
			return (path, .created)
		case .itemRemoved(let path, _, _, _):
			return (path, .deleted)
		case .itemInodeMetadataModified(let path, _, _, _):
			return (path, .changed)
		case .itemRenamed(let path, _, _, _):
			return (path, .changed)
		case .itemDataModified(let path, _, _, _):
			return (path, .changed)
		case .itemFinderInfoModified:
			break
		case .itemOwnershipModified:
			break
		case .itemXattrModified:
			break
		case .itemClonedAtPath:
			break
		}

		return nil
	}
}

// this probably belongs in LanguageServerProtocol
extension FileChangeType {
	func matches(kind: WatchKind) -> Bool {
		switch self {
		case .changed:
			return kind.contains(.change)
		case .created:
			return kind.contains(.create)
		case .deleted:
			return kind.contains(.delete)
		}
	}
}

#if compiler(>=5.9)
public struct FileEventAsyncSequence: AsyncSequence {
	public typealias Element = FileEvent
	public struct FileEventAsyncIterator: AsyncIteratorProtocol {
		private let stream: AsyncCompactMapSequence<FSEventAsyncStream, Element>
		private var internalIterator: AsyncCompactMapSequence<FSEventAsyncStream, Element>.Iterator

		init(root: URI, kind: WatchKind, pattern: Glob.Pattern, filterInProcessChanges: Bool) {
			let flags = FSEventStreamCreateFlags(
				kFSEventStreamCreateFlagFileEvents
//				filterInProcessChanges ? kFSEventStreamCreateFlagIgnoreSelf : kFSEventStreamCreateFlagNone
			)

			self.stream = FSEventAsyncStream(path: root, flags: flags)
				.compactMap { FileEventAsyncIterator.handleEvent($0, kind: kind, pattern: pattern) }

			self.internalIterator = stream.makeAsyncIterator()
		}

		public mutating func next() async -> Element? {
			await internalIterator.next()
		}

		static func handleEvent(_ event: FSEvent, kind: WatchKind, pattern: Glob.Pattern) -> Element? {
			guard let (path, type) = event.pathTypePair else { return nil }
			guard type.matches(kind: kind) else { return nil }

			guard pattern.match(path) else { return nil }

			let url = URL(fileURLWithPath: path)

			return FileEvent(uri: url.absoluteString, type: type)
		}
	}

	public let kind: WatchKind
	public let pattern: Glob.Pattern
	public let root: URL
	public let filterInProcessChanges: Bool

	public init(watcher: FileSystemWatcher, root: URL, filterInProcessChanges: Bool = true) throws {
		self.kind = watcher.kind ?? []
		// Options will have to be tweaked eventually to match what LSP actually supports.
		// But this is a good start.
		self.pattern = try Glob.Pattern(watcher.globPattern, options: .default)
		self.root = root
		self.filterInProcessChanges = filterInProcessChanges
	}

	public func makeAsyncIterator() -> FileEventAsyncIterator {
		FileEventAsyncIterator(root: root.path, kind: kind, pattern: pattern, filterInProcessChanges: filterInProcessChanges)
	}

}
#endif

#endif
