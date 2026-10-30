import XCTest
@testable import Roko

/// History read off the main thread at launch: what is visited while it is
/// read is added to it, and the file isn't written with only that.
@MainActor
final class HistoryLoadTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "history-load-\(getpid())", 1)
        }
        super.setUp()
    }

    func testAVisitWhileReadingIsKeptWithTheRest() throws {
        let name = "history-load-\(UUID().uuidString).json"
        let file = Store.file(name)
        let saved: [[String: Any]] = [
            ["url": "https://old.example/", "key": "https://old.example/", "title": "Old", "count": 4,
             "last": Date().timeIntervalSinceReferenceDate],
        ]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        let history = History(file: name, inBackground: true)
        history.record(URL(string: "https://new.example/")!, title: "New")
        history.settle()
        let read = expectation(description: "read and saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { read.fulfill() }
        wait(for: [read], timeout: 5)
        Disk.drain()
        let urls = history.everything().map(\.url.absoluteString)
        XCTAssertTrue(urls.contains("https://old.example/"), "\(urls)")
        XCTAssertTrue(urls.contains("https://new.example/"), "\(urls)")
        // And the file holds both: the save waited for the reading.
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] ?? []
        XCTAssertEqual(Set(written.compactMap { $0["url"] as? String }), ["https://old.example/", "https://new.example/"])
        try? FileManager.default.removeItem(at: file)
    }
}
