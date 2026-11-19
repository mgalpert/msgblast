import XCTest
import msgblastCore

final class MessageTextMeasurementTests: XCTestCase {
    private let longDraft = String(repeating: "Long pasted draft text. ", count: 400)

    func testCappedMeasurementMatchesFullMeasurementForShortText() {
        let text = "Short reply\nwith two lines"
        XCTAssertEqual(MessageTextMeasurement.size(text, width: 320, maxHeight: 100), MessageTextMeasurement.size(text, width: 320))
    }

    func testCappedMeasurementOfLongTextThatFitsMatchesFullMeasurement() {
        XCTAssertEqual(MessageTextMeasurement.size(longDraft, width: 100_000, maxHeight: 100), MessageTextMeasurement.size(longDraft, width: 100_000))
    }

    func testCappedMeasurementStillReportsOverflow() {
        XCTAssertGreaterThan(MessageTextMeasurement.size(longDraft, width: 320, maxHeight: 100).height, 100)
    }

    func testZeroWidthProbeOfLongParagraphReturnsQuickly() {
        // One paragraph of ~100k characters: uncapped, a 1 pt probe takes about half a second.
        let paragraph = String(repeating: longDraft, count: 10)
        _ = MessageTextMeasurement.size("Warm up fonts", width: 320)
        let start = Date()
        _ = MessageTextMeasurement.size(paragraph, width: 0, maxHeight: 100)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }
}
