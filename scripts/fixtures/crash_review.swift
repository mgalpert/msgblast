import Foundation
import msgblastCore

@main
struct CrashReviewFixture {
    @MainActor static func main() async throws {
        precondition(Bundle.main.object(forInfoDictionaryKey: "msgblastDemo") as? Bool == true)
        precondition(Bundle.main.object(forInfoDictionaryKey: "msgblastFeedbackEndpoint") as? String == "http://127.0.0.1:8128/api/feedback")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        let body: [String: Any] = ["bundleInfo": ["CFBundleIdentifier": "com.msgblast.demo", "CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "40"], "procPath": "/Applications/msgblast.app/Contents/MacOS/msgblast", "captureTime": formatter.string(from: Date().addingTimeInterval(-60)), "exception": ["type": "EXC_CRASH", "signal": "SIGABRT"], "usedImages": [["uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "arch": "arm64"]], "threads": [["triggered": true, "frames": [["imageIndex": 0, "imageOffset": 1234]]]]]
        let raw = Data("{\"bug_type\":\"309\",\"incident_id\":\"12345678-1234-1234-1234-123456789abc\"}\n".utf8) + (try JSONSerialization.data(withJSONObject: body))
        guard let crash = CrashReport.parse(raw, bundleIdentifier: "com.msgblast.demo", appPath: "/Applications/msgblast.app") else { fatalError("Synthetic report did not parse") }
        let secondRaw = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "12345678-1234-1234-1234-123456789abc", with: "87654321-1234-1234-1234-123456789abc")
        guard let second = CrashReport.parse(Data(secondRaw.utf8), bundleIdentifier: "com.msgblast.demo", appPath: "/Applications/msgblast.app") else { fatalError("Second report did not parse") }
        let store = try CrashReportStore(directory: root)
        let selection = CrashReviewSession(reports: [crash, second], store: store)
        selection.note = "Context for the first report"
        selection.selection = 1
        precondition(selection.note.isEmpty, "Changing reports must clear unrelated context")
        let session = CrashReviewSession(reports: [crash], store: store)
        try await checkRequests(0, stored: 0)
        precondition(store.attempt(crash) == nil, "Opening review must not prepare an upload")
        session.note = "Synthetic optional context"
        session.send()
        await finished(session)
        precondition(!session.sent && store.attempt(crash) != nil, "Uncertain result must retain frozen attempt")
        try await checkRequests(1, stored: 1)
        session.cleanup()
        let reopenedStore = try CrashReportStore(directory: root)
        let reopened = CrashReviewSession(reports: reopenedStore.pendingReports, store: reopenedStore)
        reopened.note = "Changed context must not replace uncertain payload"
        reopened.send()
        await finished(reopened)
        precondition(reopened.sent && reopened.pending == nil, "Identical retry must confirm receipt")
        try await checkRequests(2, stored: 1)
        reopened.send()
        try await checkRequests(2, stored: 1)
        let oversizedRoot = root.appendingPathComponent("oversized")
        let oversizedStore = try CrashReportStore(directory: oversizedRoot)
        let oversized = CrashReviewSession(reports: [crash], store: oversizedStore)
        oversized.note = String(repeating: "👨‍👩‍👧‍👦", count: 1600)
        oversized.send()
        precondition(oversizedStore.attempt(crash) == nil, "Oversized context must remain editable rather than becoming a frozen retry")
        try await checkRequests(2, stored: 1)
        print("PASS: review sends nothing; explicit send; uncertain acknowledgement; frozen retry after relaunch; one stored report; duplicate send blocked; oversized context remains editable")
    }
    @MainActor private static func finished(_ session: CrashReviewSession) async {
        for _ in 0..<150 {
            if !session.sending { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        fatalError("Fixture submission did not finish")
    }
    private static func checkRequests(_ count: Int, stored: Int) async throws {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8128/fixture-status")!)
        let status = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let requests = status["requests"] as! [[String: String]]
        precondition(requests.count == count && status["stored"] as? Int == stored)
        if requests.count == 2 {
            precondition(requests[0] == requests[1], "Retry must retain original ID and context")
        }
    }
}
