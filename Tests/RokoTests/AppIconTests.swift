import AppKit
import XCTest
@testable import Roko

/// Settings › Appearance › App icon (AppIcon.swift).
@MainActor
final class AppIconTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "app-icon-\(getpid())", 1)
        }
        super.setUp()
    }

    func testEveryColourwayDrawsAndYoursWaitsForAPicture() throws {
        for choice in AppIconChoice.allCases where choice != .own {
            let image = try XCTUnwrap(AppIcon.image(choice, size: 128))
            XCTAssertEqual(image.size, NSSize(width: 128, height: 128))
        }
        try? FileManager.default.removeItem(at: AppIcon.ownFile)
        XCTAssertNil(AppIcon.image(.own))
    }

    func testAPictureOfYoursIsCutToTheTileFromItsMiddle() throws {
        // A wide red picture with a blue middle: the tile's centre is blue,
        // its corner (outside the rounded tile) clear.
        let wide = NSImage(size: NSSize(width: 300, height: 100), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill()
            NSColor.blue.setFill(); NSRect(x: 100, y: 0, width: 100, height: 100).fill()
            return true
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(data: try XCTUnwrap(wide.tiffRepresentation))!
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertTrue(AppIcon.adopt(source))
        let kept = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: AppIcon.ownFile)))
        XCTAssertEqual(kept.pixelsWide, 1024)
        let middle = try XCTUnwrap(kept.colorAt(x: 512, y: 512)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(middle.blueComponent, 0.8)
        XCTAssertLessThan(middle.redComponent, 0.2)
        XCTAssertEqual(kept.colorAt(x: 105, y: 105)?.alphaComponent ?? 1, 0, accuracy: 0.05)
        XCTAssertNotNil(AppIcon.image(.own))
        try? FileManager.default.removeItem(at: AppIcon.ownFile)

        // Not a picture: refused, nothing kept.
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("not-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        XCTAssertFalse(AppIcon.adopt(text))
    }
}
