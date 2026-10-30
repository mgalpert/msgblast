
// Appended to the production audio source by test_gptlive_audio.sh so this can
// exercise the private converter. --hardware also opens the default audio route.
@main struct GPTLiveAudioChecks {
    @MainActor static func main() async throws {
        precondition(GPTLiveAudio.level(of: Data()) == 0)
        precondition(GPTLiveAudio.level(of: Data(repeating: 0, count: 480)) == 0, "Silent streaming must not look like speaking")
        precondition(GPTLiveAudio.level(of: Data([0, 64, 0, 192])) > 0.8, "The meter must respond to positive and negative PCM samples")
        precondition(GPTLiveAudio.level(of: Data([0, 128])) == 1, "Int16.min must not overflow")
        precondition(GPTLiveAudio.level(of: Data([255])) == 0, "An incomplete sample has no measured level")
        var permission: CheckedContinuation<Bool, Never>?
        let waitingAudio = GPTLiveAudio(requestPermission: { await withCheckedContinuation { permission = $0 } })
        let pendingStart = Task {
            do {
                try await waitingAudio.start { _ in preconditionFailure("Cancelled permission must never deliver audio") }
                preconditionFailure("Cancelled permission must not start capture")
            } catch is CancellationError { }
        }
        while permission == nil { await Task.yield() }
        waitingAudio.stop()
        permission?.resume(returning: true)
        try await pendingStart.value
        precondition(!waitingAudio.isCapturing && waitingAudio.inputLevel == 0 && waitingAudio.outputLevel == 0)
        GPTLiveAudio.checkMutePreservesPlayback()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<2 {
            for frame in 0..<4_800 { buffer.floatChannelData![channel][frame] = 0.25 }
        }
        let pipeline = try GPTLiveCapturePipeline(inputFormat: format) { _ in }
        pipeline.consume(buffer)
        let output = pipeline.takeDelivery()
        precondition(output.error == nil && output.pcm.count > 4_000 && output.pcm.count <= 4_800)
        precondition(output.pcm.count.isMultiple(of: 2))
        let offset = output.pcm.count / 4 * 2
        let sample = Int16(bitPattern: UInt16(output.pcm[offset]) | UInt16(output.pcm[offset + 1]) << 8)
        precondition(abs(Int(sample) - 8_192) < 100, "Expected mono PCM16 little-endian samples")
        pipeline.setMuted(true)
        pipeline.consume(buffer)
        precondition(pipeline.takeDelivery().pcm.isEmpty)
        pipeline.setMuted(false)
        pipeline.consume(buffer)
        precondition(!pipeline.takeDelivery().pcm.isEmpty)
        pipeline.deactivate()
        pipeline.consume(buffer)
        precondition(pipeline.takeDelivery().pcm.isEmpty)
        let bounded = try GPTLiveCapturePipeline(inputFormat: format) { _ in }
        for _ in 0..<8 { bounded.consume(buffer) }
        let overflow = bounded.takeDelivery()
        precondition(overflow.error != nil && overflow.pcm.isEmpty, "Backpressure must stop and drop pending audio")
        if CommandLine.arguments.contains("--hardware") {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw NSError(domain: "GPTLiveHardwareCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission must already be authorized; this check does not request access."])
            }
            let audio = GPTLiveAudio()
            audio.onDiagnostic = { print($0) }
            var bytes = 0
            var peak = 0
            try await audio.start { pcm in
                bytes += pcm.count
                pcm.withUnsafeBytes { raw in
                    let samples = raw.bindMemory(to: UInt8.self)
                    for offset in stride(from: 0, to: samples.count, by: 2) {
                        let sample = Int16(bitPattern: UInt16(samples[offset]) | UInt16(samples[offset + 1]) << 8)
                        peak = max(peak, abs(Int(sample)))
                    }
                }
            }
            try await Task.sleep(for: .seconds(1))
            precondition(audio.isCapturing && bytes > 24000, "The real microphone must deliver converted audio for at least half a second")
            // Silent playback exercises the completion callback without audible output.
            audio.play(Data(repeating: 0, count: 4800))
            try await Task.sleep(for: .milliseconds(200))
            precondition(audio.error == nil, "Silent playback must not report an error")
            let playbackEngine = audio.testEngine
            audio.setMuted(true)
            let mutedBytes = bytes
            try await Task.sleep(for: .milliseconds(150))
            precondition(bytes == mutedBytes && audio.testEngine === playbackEngine)
            try await audio.start { bytes += $0.count }
            try await Task.sleep(for: .milliseconds(150))
            precondition(bytes > mutedBytes && audio.testEngine === playbackEngine, "Unmute must reuse the running audio graph")
            audio.stop()
            let stoppedBytes = bytes
            try await Task.sleep(for: .milliseconds(150))
            precondition(!audio.isCapturing && bytes == stoppedBytes)
            print("PASS: hardware microphone startup, \(bytes) converted PCM bytes (peak \(peak)/32768), silent playback and teardown. Audio is neither saved nor uploaded.")
            bytes = 0
            try await audio.start { bytes += $0.count }
            try await Task.sleep(for: .milliseconds(500))
            precondition(audio.isCapturing && bytes > 0, "Capture must restart after stopping")
            audio.stop()
            print("PASS: hardware microphone restart.")
        }
        print("PASS: production audio conversion — stereo 48 kHz to mono PCM16 24 kHz, byte order, mute, shutdown and bounded capture queue.")
    }
}

private extension GPTLiveAudio {
    static func checkMutePreservesPlayback() {
        let mutedAudio = GPTLiveAudio(requestPermission: { true })
        mutedAudio.queuedFrames = 1200
        let playbackID = mutedAudio.playbackID
        mutedAudio.setMuted(true)
        precondition(mutedAudio.queuedFrames == 1200 && mutedAudio.playbackID == playbackID,
                     "Muting input must preserve queued assistant speech")
        mutedAudio.setMuted(false)
        precondition(mutedAudio.queuedFrames == 1200 && mutedAudio.playbackID == playbackID)
        mutedAudio.stop()
        precondition(mutedAudio.queuedFrames == 0 && mutedAudio.playbackID != playbackID)
    }
    var testEngine: AVAudioEngine? { engine }
}
