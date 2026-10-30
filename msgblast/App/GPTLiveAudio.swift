import AVFoundation
import Combine
import CoreAudio
import Foundation

/// The GPT-Live WebSocket format is raw mono PCM16 little-endian at 24 kHz.
/// No audio device is opened until `start` or `play` is explicitly called.
@MainActor
final class GPTLiveAudio: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var error: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var outputLevel = 0.0

    var onDiagnostic: (@MainActor (String) -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var inputNode: AVAudioInputNode?
    private var capturePipeline: GPTLiveCapturePipeline?
    private var configurationObserver: NSObjectProtocol?
    private var lifecycleID = UUID()
    private var engineID = UUID()
    private var playbackID = UUID()
    private var queuedFrames = 0
    private var trailingOutputByte: UInt8?
    private var isMuted = false
    private var onPCM: (@MainActor (Data) -> Void)?
    private var lastInputMeterUpdate = 0.0
    private var lastOutputMeterUpdate = 0.0
    private let requestPermission: @MainActor () async -> Bool

    private static let sampleRate = 24_000.0
    private static let maximumQueuedFrames = 24_000 * 6

    init(requestPermission: (@MainActor () async -> Bool)? = nil) {
        self.requestPermission = requestPermission ?? {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        }
    }

    /// Check consent without opening a device or starting a remote session.
    func requestMicrophoneAccess() async throws {
        try Task.checkCancellation()
        let permitted = await requestPermission()
        try Task.checkCancellation()
        permissionDenied = !permitted
        guard permitted else {
            throw GPTLiveAudioError("Microphone access is off. Allow this app in System Settings → Privacy & Security → Microphone, then try again.")
        }
    }

    func start(onPCM: @escaping @MainActor (Data) -> Void) async throws {
        if engine?.isRunning == true, capturePipeline != nil {
            let requestID = lifecycleID
            try await requestMicrophoneAccess()
            guard lifecycleID == requestID else { throw CancellationError() }
            self.onPCM = onPCM
            setMuted(false)
            return
        }
        stop()
        error = nil
        let requestID = lifecycleID

        do {
            try await requestMicrophoneAccess()

            // Stop, a newer start, or cancellation while the permission dialog is
            // open must never turn the microphone on when that dialog finishes.
            try Task.checkCancellation()
            guard lifecycleID == requestID else { throw CancellationError() }
            releaseEngine()
            let newEngine = AVAudioEngine()
            let newPlayer = AVAudioPlayerNode()
            let input = newEngine.inputNode
            // Voice processing can accept a virtual route, then fail at engine
            // startup with -10875 and leave the process's audio route unusable.
            // Keep virtual/aggregate routes on ordinary capture from the start.
            if Self.canUseVoiceProcessing() {
                try? input.setVoiceProcessingEnabled(true)
            }
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw GPTLiveAudioError("No microphone is available. Connect an input device and start listening again.")
            }

            self.onPCM = onPCM
            isMuted = false
            let pipeline = try GPTLiveCapturePipeline(inputFormat: inputFormat) { [weak self] pipeline in
                Task { @MainActor [weak self] in
                    let delivery = pipeline.takeDelivery()
                    guard let self, self.lifecycleID == requestID,
                          self.capturePipeline === pipeline else { return }
                    if let failure = delivery.error {
                        self.stop()
                        self.error = failure
                    } else if self.isCapturing, !self.isMuted, !delivery.pcm.isEmpty {
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - self.lastInputMeterUpdate >= 0.05 {
                            let level = Self.level(of: delivery.pcm)
                            if self.inputLevel != level { self.inputLevel = level }
                            self.lastInputMeterUpdate = now
                        }
                        self.onPCM?(delivery.pcm)
                    }
                }
            }
            pipeline.setMuted(isMuted)
            try configurePlayback(newEngine, player: newPlayer)
            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { @Sendable buffer, _ in
                pipeline.consume(buffer)
            }
            engine = newEngine
            player = newPlayer
            inputNode = input
            capturePipeline = pipeline
            newEngine.prepare()
            try Task.checkCancellation()
            try newEngine.start()
            try Task.checkCancellation()
            isCapturing = true
            observeConfiguration(of: newEngine)
            onDiagnostic?("Capture started: \(inputFormat.channelCount) channels at \(Int(inputFormat.sampleRate)) Hz → mono PCM16 at 24000 Hz. "
                + (input.isVoiceProcessingEnabled ? "Apple voice processing enabled." : "Apple voice processing bypassed for this route; use headphones to prevent speaker echo."))
        } catch {
            // An old permission request must not stop a newer recording.
            if lifecycleID == requestID {
                stop()
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            throw error
        }
    }

    func stop() {
        lifecycleID = UUID()
        releaseEngine()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        capturePipeline?.setMuted(muted)
        if muted && inputLevel != 0 { inputLevel = 0 }
    }

    /// Queues decoded output bytes in arrival order, including split samples.
    /// Playback can be used without microphone permission or capture.
    func play(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        guard pcm.count <= Self.maximumQueuedFrames * 2 else {
            stopPlayback()
            error = "An audio response exceeded the playback buffer. Playback was cleared."
            return
        }

        var bytes = Data()
        if let trailingOutputByte { bytes.append(trailingOutputByte) }
        bytes.append(pcm)
        let frameCount = bytes.count / 2
        trailingOutputByte = bytes.count.isMultiple(of: 2) ? nil : bytes.last
        guard frameCount > 0 else { return }
        guard queuedFrames + frameCount <= Self.maximumQueuedFrames else {
            stopPlayback()
            error = "Audio playback fell behind. Queued speech was cleared to keep the conversation live."
            return
        }

        do {
            try ensurePlaybackEngine()
            guard let player, let format = Self.playbackFormat(),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
                  let samples = buffer.floatChannelData?[0] else {
                throw GPTLiveAudioError("The audio output buffer could not be created.")
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            bytes.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: UInt8.self)
                for index in 0..<frameCount {
                    let bits = UInt16(source[index * 2]) | (UInt16(source[index * 2 + 1]) << 8)
                    samples[index] = Float(Int16(bitPattern: bits)) / 32_768
                }
            }
            let scheduledID = playbackID
            queuedFrames += frameCount
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackID == scheduledID else { return }
                    self.queuedFrames = max(0, self.queuedFrames - frameCount)
                    if self.queuedFrames == 0 && self.outputLevel != 0 { self.outputLevel = 0 }
                }
            }
            if !player.isPlaying { player.play() }
        } catch {
            stopPlayback()
            self.error = error.localizedDescription
        }
    }

    func stopPlayback() {
        // Completion callbacks for stopped buffers may still arrive.
        playbackID = UUID()
        queuedFrames = 0
        trailingOutputByte = nil
        if outputLevel != 0 { outputLevel = 0 }
        lastOutputMeterUpdate = 0
        player?.stop()
        player?.reset()
    }

    private static func playbackFormat() -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    }

    /// A display-only RMS meter. Silent PCM must stay at zero: GPT-Live can
    /// stream silence between words, which is not a speaking indication.
    nonisolated static func level(of pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        let power = pcm.withUnsafeBytes { raw -> Double in
            let bytes = raw.bindMemory(to: UInt8.self)
            var sum = 0.0
            for index in 0..<count {
                let bits = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
                let sample = Double(Int16(bitPattern: bits)) / 32768
                sum += sample * sample
            }
            return sum / Double(count)
        }
        let rms = sqrt(power)
        return rms < 0.004 ? 0 : min(1, sqrt(rms) * 1.6)
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var power = 0.0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let sample = Double(buffer.format.isInterleaved
                    ? channels[0][frame * Int(buffer.format.channelCount) + channel]
                    : channels[channel][frame])
                power += sample * sample
            }
        }
        let rms = sqrt(power / Double(buffer.frameLength * buffer.format.channelCount))
        return rms < 0.004 ? 0 : min(1, sqrt(rms) * 1.6)
    }

    private static func canUseVoiceProcessing() -> Bool {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
                  device != kAudioObjectUnknown else { return false }
            address.mSelector = kAudioDevicePropertyTransportType
            var transport: UInt32 = kAudioDeviceTransportTypeUnknown
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
            switch transport {
            case kAudioDeviceTransportTypeUnknown, kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeRemoteScreen, kAudioDeviceTransportTypeRemoteStreaming:
                return false
            default:
                continue
            }
        }
        return true
    }

    private func configurePlayback(_ engine: AVAudioEngine, player: AVAudioPlayerNode) throws {
        let hardwareFormat = engine.outputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              let format = Self.playbackFormat() else {
            throw GPTLiveAudioError("No audio output is available. Connect speakers or headphones and try again.")
        }
        engine.attach(player)
        // The mixer handles output hardware sample rates; the player receives
        // correctly decoded 24 kHz floating-point samples, never relabeled PCM.
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Meter rendered output, not arriving network packets, which can be
        // several seconds ahead of the sound the user is actually hearing.
        let observedID = engineID
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { @Sendable [weak self] buffer, _ in
            let level = Self.level(of: buffer)
            Task { @MainActor [weak self] in
                guard let self, self.engineID == observedID, self.queuedFrames > 0, self.player?.isPlaying == true else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastOutputMeterUpdate >= 0.05 else { return }
                if self.outputLevel != level { self.outputLevel = level }
                self.lastOutputMeterUpdate = now
            }
        }
    }

    private func ensurePlaybackEngine() throws {
        if let engine, engine.isRunning { return }
        // A device change may stop an existing graph before its notification is
        // delivered. Do not silently restart microphone capture in that state.
        if engine != nil { stop() }
        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        try configurePlayback(newEngine, player: newPlayer)
        newEngine.prepare()
        try newEngine.start()
        engine = newEngine
        player = newPlayer
        observeConfiguration(of: newEngine)
    }

    private func observeConfiguration(of observedEngine: AVAudioEngine) {
        let observedID = engineID
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: observedEngine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.engineID == observedID else { return }
                self.stop()
                self.error = "The audio device changed. Start listening again to use the new device."
            }
        }
    }

    private func releaseEngine() {
        engineID = UUID()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        capturePipeline?.deactivate()
        if let inputNode { inputNode.removeTap(onBus: 0) }
        inputNode = nil
        capturePipeline = nil
        onPCM = nil
        isCapturing = false
        if inputLevel != 0 { inputLevel = 0 }
        lastInputMeterUpdate = 0
        stopPlayback()
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()
        player = nil
        engine = nil
    }

    isolated deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        capturePipeline?.deactivate()
        if let inputNode { inputNode.removeTap(onBus: 0) }
        player?.stop()
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
    }
}

private struct GPTLiveAudioError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// AVAudioEngine invokes taps off the main actor. This object exclusively owns
/// the converter, and its lock protects every mutable field and converter call.
/// Only Data crosses to the main actor; the tap's borrowed buffer never escapes.
private final class GPTLiveCapturePipeline: @unchecked Sendable {
    struct Delivery: Sendable {
        let pcm: Data
        let error: String?
    }

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let schedule: @Sendable (GPTLiveCapturePipeline) -> Void
    private var active = true
    private var muted = false
    private var deliveryScheduled = false
    private var pendingPCM = Data()
    private var pendingError: String?
    // Half a second is enough for normal UI scheduling; stop instead of building
    // an unbounded queue when the consumer cannot keep up.
    private let maximumPendingBytes = 24_000

    init(inputFormat: AVAudioFormat, schedule: @escaping @Sendable (GPTLiveCapturePipeline) -> Void) throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw GPTLiveAudioError("This microphone's format cannot be converted to 24 kHz audio.")
        }
        self.outputFormat = output
        self.converter = converter
        self.schedule = schedule
        converter.primeMethod = .none
        converter.downmix = inputFormat.channelCount > 1
    }

    func setMuted(_ muted: Bool) {
        lock.withLock {
            self.muted = muted
            pendingPCM.removeAll(keepingCapacity: true)
            converter.reset()
        }
    }

    func deactivate() {
        lock.withLock {
            active = false
            pendingPCM.removeAll()
            pendingError = nil
        }
    }

    func takeDelivery() -> Delivery {
        lock.withLock {
            let result = Delivery(pcm: pendingPCM, error: pendingError)
            pendingPCM = Data()
            pendingError = nil
            deliveryScheduled = false
            return result
        }
    }

    func consume(_ input: AVAudioPCMBuffer) {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard active, !muted, input.frameLength > 0 else { return false }
            let capacity = ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate) + 64
            guard capacity <= Double(maximumPendingBytes / 2),
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else {
                return fail("The microphone produced an unsupported audio buffer. Start listening again.")
            }
            let source = ConversionInput(input)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                source.take(inputStatus)
            }
            guard status != .error, conversionError == nil else {
                return fail("Microphone audio conversion failed. Start listening again.")
            }
            guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return false }
            let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
            guard pendingPCM.count + byteCount <= maximumPendingBytes else {
                return fail("Microphone audio could not be sent in real time. Start listening again.")
            }
            // Supported Macs are little-endian, matching the PCM wire format.
            pendingPCM.append(UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: byteCount)
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule { schedule(self) }
    }

    // Caller holds `lock`.
    private func fail(_ message: String) -> Bool {
        active = false
        pendingPCM.removeAll()
        pendingError = message
        guard !deliveryScheduled else { return false }
        deliveryScheduled = true
        return true
    }

    /// The converter's input block is imported as Sendable. Its borrowed source
    /// stays inside the synchronous conversion call and is yielded only once.
    private final class ConversionInput: @unchecked Sendable {
        private let lock = NSLock()
        private let buffer: AVAudioPCMBuffer
        private var supplied = false

        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.withLock {
                guard !supplied else {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
        }
    }
}
