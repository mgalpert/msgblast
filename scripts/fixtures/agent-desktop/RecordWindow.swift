import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    func waitForFinish() { _ = finished.wait(timeout: .now() + 10) }
    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) { finished.signal() }
    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) { print("Recording failed: \(error)"); finished.signal() }
}
@main struct RecordWindow {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 3, let id = UInt32(CommandLine.arguments[1]) else { exit(2) }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == id }), window.owningApplication?.bundleIdentifier == "com.msgblast.grok-transport-fixture" else { exit(2) }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = false
        config.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        outputConfig.videoCodecType = .h264
        outputConfig.outputFileType = .mp4
        let delegate = RecordingDelegate()
        try stream.addRecordingOutput(SCRecordingOutput(configuration: outputConfig, delegate: delegate))
        try await stream.startCapture()
        FileHandle.standardOutput.write(Data("READY\n".utf8))
        _ = await Task.detached { FileHandle.standardInput.readData(ofLength: 1) }.value
        try await stream.stopCapture()
        await Task.detached { delegate.waitForFinish() }.value
    }
}
