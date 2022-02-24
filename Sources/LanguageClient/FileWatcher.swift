import Foundation
import LanguageServerProtocol

#if canImport(FSEventsWrapper) && canImport(Glob)
import FSEventsWrapper
import Glob

public class FileWatcher {
    public typealias Handler = ([FileEvent]) -> Void

    public let params: FileSystemWatcher
    public let root: String
    private lazy var stream: FSEventStream? = {
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)

        return FSEventStream(path: root, fsEventStreamFlags: flags) { [weak self] _, event in
            self?.handleEvent(event)
        }
    }()
    private var lastSet: Set<String>
    public var handler: Handler
    private var pathDates: [String : Date]
    private var watchDate: Date
    private let queue: OperationQueue

    public init(root: String, params: FileSystemWatcher) {
        self.root = root
        self.params = params
        self.lastSet = Set()
        self.pathDates = [:]
        self.watchDate = .distantPast
        self.queue = OperationQueue(name: "com.chimehq.LanguageClient.FileWatcher", maxConcurrentOperations: 1)

        handler = { _ in }
    }

    public func start() {
        queue.addOperation {
            self.lastSet = self.captureCurrentFileSet()
            self.watchDate = Date()

            // this matters, because streams are runloop-based
            OperationQueue.main.addOperation {
                self.stream?.startWatching()
            }
        }
    }

    public func stop() {
        OperationQueue.main.addOperation {
            self.stream?.stopWatching()

            self.queue.addOperation {
                self.lastSet = Set()
                self.pathDates.removeAll()
                self.watchDate = .distantPast
            }
        }
    }

    private func captureCurrentFileSet() -> Set<String> {
        let glob = Glob(pattern: params.globPattern)
        var set = Set<String>()

        for path in glob {
            set.insert(path)
        }

        return set
    }

    private func handleEvent(_ event: FSEvent) {
        switch event {
        case .generic(let path, _, _):
            handleChange(path)
        case .mustScanSubDirs(let path, _):
            handleChange(path)
        case .eventIdsWrapped:
            break
        case .streamHistoryDone:
            break
        case .rootChanged(let path, _):
            handleChange(path)
        case .volumeMounted(let path, _, _):
            handleChange(path)
        case .volumeUnmounted(let path, _, _):
            handleChange(path)
        case .itemCreated(let path, _, _, _):
            handleChange(path)
        case .itemRemoved(let path, _, _, _):
            handleChange(path)
        case .itemInodeMetadataModified(let path, _, _, _):
            handleChange(path)
        case .itemRenamed(let path, _, _, _):
            handleChange(path)
        case .itemDataModified(let path, _, _, _):
            handleChange(path)
        case .itemFinderInfoModified:
            break
        case .itemOwnershipModified:
            break
        case .itemXattrModified:
            break
        case .itemClonedAtPath(let path, _, _, _):
            handleChange(path)
        }
    }

    private func handleChange(_ path: String) {
        queue.addOperation {
            let currentSet = self.captureCurrentFileSet()

            let date = self.pathDates[path, default: self.watchDate]

            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                return
            }

            let dirPath = path.hasSuffix("/") ? path : path + "/"
            let subpaths = contents.map({ dirPath + $0 }) + [path]

            let events = subpaths.compactMap({ self.computeEventType(for: $0, currentSet: currentSet, date: date) })

            // we have to now record the dates last checked on a per-path basis
            for subpath in subpaths {
                self.pathDates[subpath] = Date()
            }

            self.lastSet = currentSet

            if events.isEmpty == false {
                self.handler(events)
            }
        }
    }

    private func computeEventType(for path: String, currentSet: Set<String>, date: Date) -> FileEvent? {
        let inCurrent = currentSet.contains(path)
        let inLast = lastSet.contains(path)
        let uri = "file://" + path

        switch (inLast, inCurrent) {
        case (false, false):
            break
        case (false, true):
            return FileEvent(uri: uri, type: .created)
        case (true, false):
            return FileEvent(uri: uri, type: .deleted)
        case (true, true):
            // ok, so in this case, we need to check dates
            guard let modDate = fileModificationDate(for: path) else { break }

            if modDate > date {
                return FileEvent(uri: uri, type: .changed)
            }
        }

        return nil
    }

    private func fileModificationDate(for path: String) -> Date? {
        let attr = try? FileManager.default.attributesOfItem(atPath: path)

        return attr?[.modificationDate] as? Date
    }
}

#endif
