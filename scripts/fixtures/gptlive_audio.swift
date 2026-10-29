
// Appended to the production audio source by test_gptlive_audio.sh so this can
// exercise the private converter. --hardware also opens the default audio route.
@main struct GPTLiveAudioChecks {
    @MainActor static func main() async throws {
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
