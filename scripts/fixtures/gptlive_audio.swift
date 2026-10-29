
// Appended to the production audio source by test_gptlive_audio.sh so this can
// exercise the private converter without opening a microphone or output device.
@main struct GPTLiveAudioChecks {
    static func main() throws {
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
        print("PASS: production audio conversion — stereo 48 kHz to mono PCM16 24 kHz, byte order, mute, shutdown and bounded capture queue; no audio devices opened.")
    }
}
