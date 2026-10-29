import AppKit
import msgblastCore

@MainActor
final class CrashReporting {
    static let shared = CrashReporting()
    private var started = false
    private var directory: URL?
    private var fixture = false
    private var prompted = false
    private var reports: [CrashReport] = []
    private var detectedReports: [CrashReport] = []
    private var store: CrashReportStore?
    private var error: String?

    func start(model: AppModel) {
        guard !started else { return }
        started = true
        directory = model.local.url.deletingLastPathComponent()
        #if DEBUG
        fixture = model.demo && ProcessInfo.processInfo.arguments.contains("--crash-report-preview")
        #endif
        Task {
            await scan()
            offer()
            // macOS may finish writing an IPS shortly after the next launch.
            for delay in [5, 25] {
                try? await Task.sleep(for: .seconds(delay))
                await scan(); offer()
            }
        }
    }
    func show() {
        Task { await scan(); CrashReportWindowController.show(reports: reports, store: store, error: error) }
    }
    private func scan() async {
        guard let directory else { error = "Open the workspace before reviewing crash reports."; return }
        do {
            if store == nil { store = try CrashReportStore(directory: directory) }
            let bundle = Bundle.main.bundleIdentifier ?? "com.msgblast.mac"
            let appPath = Bundle.main.bundleURL.path
            let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
            let fixture = self.fixture
            let collected = await Task.detached {
                if fixture { return Self.fixtureReport(bundle: bundle, appPath: appPath).map { [$0] } ?? [] }
                return CrashReport.collect(directory: logs, bundleIdentifier: bundle, appPath: appPath)
            }.value
            detectedReports = collected
            let incidents = Set(collected.map(\.incident))
            reports = collected + (store?.pendingReports.filter { !incidents.contains($0.incident) } ?? [])
            error = nil
        } catch {
            store = nil; reports = []
            self.error = "The crash report journal could not be opened. Nothing was sent. Your app data is unchanged."
        }
    }
    private func offer() {
        guard !prompted, let store, let report = detectedReports.first(where: { store.shouldOffer($0) }) else { return }
        prompted = true
        let alert = NSAlert()
        alert.messageText = fixture ? "Demo fixture: earlier crash found" : "msgblast found an earlier crash"
        alert.informativeText = "You can review a limited crash summary and choose whether to send it privately to help us fix the problem. Nothing has been uploaded."
        alert.addButton(withTitle: "Review report")
        alert.addButton(withTitle: "Not now")
        if alert.runModal() == .alertFirstButtonReturn {
            CrashReportWindowController.show(reports: [report] + reports.filter { $0.incident != report.incident }, store: store)
        } else {
            do { try store.dismiss(report) }
            catch { self.error = "Could not remember dismissal. Nothing was sent." }
        }
    }
    nonisolated private static func fixtureReport(bundle: String, appPath: String) -> CrashReport? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        let body: [String: Any] = [
            "bundleInfo": ["CFBundleIdentifier": bundle, "CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "40"],
            "procPath": appPath + "/Contents/MacOS/msgblast", "captureTime": formatter.string(from: Date().addingTimeInterval(-60)),
            "exception": ["type": "EXC_CRASH", "signal": "SIGABRT", "message": "Excluded synthetic private text"],
            "usedImages": [["uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "arch": "arm64"]],
            "threads": [["triggered": true, "frames": [["imageIndex": 0, "imageOffset": 1234]]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return CrashReport.parse(Data("{\"bug_type\":\"309\",\"incident_id\":\"12345678-1234-1234-1234-123456789abc\"}\n".utf8) + data, bundleIdentifier: bundle, appPath: appPath)
    }
}
