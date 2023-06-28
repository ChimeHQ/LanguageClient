import XCTest
import LanguageClient
import LanguageServerProtocol

final class FileEventAsyncSequenceTests: XCTestCase {
	func testCreateEvent() async throws {
		let watcher = FileSystemWatcher(globPattern: "*/create_test", kind: [.all])

		// it's pretty strange to do this, but file event system delivers paths with "/private" prepended. And while they are equivalent paths, actually checking that is really annoying.
		let testDir = URL(filePath: "/private" + NSTemporaryDirectory() + "event_tests")
		let testFileURL = testDir.appending(component: "create_test")

		try? FileManager.default.removeItem(at: testDir)
		try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

		let sequence = try FileEventAsyncSequence(watcher: watcher, root: testDir, filterInProcessChanges: false)
		var iterator = sequence.makeAsyncIterator()

		let exp = expectation(description: "created file")

		Task {
			// careful not to use atomic here, as that has differnt behavior
			try! Data().write(to: testFileURL, options: [.withoutOverwriting])

			exp.fulfill()
		}

		await fulfillment(of: [exp])

		// we have to be careful here, as our delete will also produce an event
		var event = await iterator.next()

		if event?.type == .deleted {
			event = await iterator.next()
		}

		XCTAssertEqual(FileEvent(uri: testFileURL.absoluteString, type: .created), event)
	}
}
