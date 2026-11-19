import XCTest
import msgblastCore

final class MessageTextMeasurementTests: XCTestCase {
    private let longDraft = String(repeating: "Long pasted draft text. ", count: 400)

    func testCappedMeasurementMatchesFullMeasurementForShortText() {
        let text = "Short reply\nwith two lines"
        XCTAssertEqual(MessageTextMeasurement.size(text, width: 320, maxHeight: 100), MessageTextMeasurement.size(text, width: 320))
    }

    func testCappedMeasurementOfLongTextThatFitsMatchesFullMeasurement() {
        // About 1,900 characters: past the first prefix, but only about four lines at 4,000 pt.
        let text = String(repeating: "Long pasted draft text. ", count: 80)
        XCTAssertEqual(MessageTextMeasurement.size(text, width: 4000, maxHeight: 100), MessageTextMeasurement.size(text, width: 4000))
        XCTAssertLessThanOrEqual(MessageTextMeasurement.size(text, width: 4000).height, 100)
    }

    func testCappedMeasurementStillReportsOverflow() {
        XCTAssertGreaterThan(MessageTextMeasurement.size(longDraft, width: 320, maxHeight: 100).height, 100)
    }

    func testZeroAndUnboundedProbesOfLongParagraphReturnQuickly() {
        // One paragraph of ~1M characters: uncapped, either probe typesets all of it.
        let paragraph = String(repeating: longDraft, count: 100)
        _ = MessageTextMeasurement.size("Warm up fonts", width: 320)
        let start = Date()
        _ = MessageTextMeasurement.size(paragraph, width: 0, maxHeight: 100)
        _ = MessageTextMeasurement.size(paragraph, width: .infinity, maxHeight: 100)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
