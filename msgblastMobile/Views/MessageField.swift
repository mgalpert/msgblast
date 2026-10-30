import AVFoundation
import Speech
import SwiftUI
import UIKit

/// A UITextView field: placeholder, body text with 12 × 8 insets, growing from one line to
/// five and scrolling after that.
struct MessageField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var focused: Bool
    /// Text inset from the field's leading edge (less when an agent badge precedes it).
    var leadingInset: CGFloat = Space.inset

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: Space.gap, left: leadingInset, bottom: Space.gap, right: Space.tight)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        let leading = label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leadingInset)
        NSLayoutConstraint.activate([leading, label.topAnchor.constraint(equalTo: view.topAnchor, constant: Space.gap)])
        context.coordinator.placeholder = label
        context.coordinator.placeholderLeading = leading
        view.accessibilityLabel = placeholder
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.textContainerInset.left != leadingInset {
            view.textContainerInset.left = leadingInset
            context.coordinator.placeholderLeading?.constant = leadingInset
        }
        if view.text != text { view.text = text }
        context.coordinator.placeholder?.text = placeholder
        context.coordinator.placeholder?.isHidden = !text.isEmpty
        view.accessibilityLabel = placeholder
        if focused && !view.isFirstResponder { DispatchQueue.main.async { view.becomeFirstResponder() } }
        if !focused && view.isFirstResponder { DispatchQueue.main.async { view.resignFirstResponder() } }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let font = view.font ?? .preferredFont(forTextStyle: .body)
        let maximum = ceil(font.lineHeight * 5) + 2 * Space.gap
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let scrolls = fitting > maximum
        if view.isScrollEnabled != scrolls { DispatchQueue.main.async { view.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: max(Space.fieldHeight, min(fitting, maximum)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MessageField
        weak var placeholder: UILabel?
        weak var placeholderLeading: NSLayoutConstraint?
        init(_ parent: MessageField) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            placeholder?.isHidden = !view.text.isEmpty
        }
        func textViewDidBeginEditing(_ view: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ view: UITextView) { if parent.focused { parent.focused = false } }
    }
}

/// Dictation on the phone with Apple's speech recognition: on device when the language
/// supports it, else Apple's service (said once). Only the text reaches the Mac.
@MainActor
final class Dictation: ObservableObject {
    enum State: Equatable { case idle, listening, denied }
    @Published private(set) var state: State = .idle
    /// A one-line note under the field: the server fallback, or how to allow access.
    @Published var note: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var interruption: NSObjectProtocol?
    private var notedServer = false
    static let silenceLimit: Duration = .seconds(60)

    /// The simulator, and a phone with no microphone, have no input: the glyph hides.
    static var hasInput: Bool { AVAudioSession.sharedInstance().isInputAvailable }

    func toggle(base: String, onText: @escaping @MainActor (String) -> Void) {
        switch state {
        case .listening: stop()
        case .denied: if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .idle: Task { await start(base: base, onText: onText) }
        }
    }

    private func start(base: String, onText: @escaping @MainActor (String) -> Void) async {
        let speech = await Self.speechAuthorization()
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, microphone else {
            state = .denied
            note = "Allow Speech Recognition and Microphone in Settings to dictate"
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { note = "Dictation is not available right now"; return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else if !notedServer {
            notedServer = true
            note = "Dictation for this language uses Apple's speech service"
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            Self.installTap(on: input, feeding: request)
            engine.prepare()
            try engine.start()
        } catch {
            note = "Dictation could not start"
            stop()
            return
        }
        self.request = request
        let prefix = base.isEmpty || base.hasSuffix(" ") ? base : base + " "
        task = Self.recognize(with: recognizer, request: request) { [weak self] text, done in
            // Results arrive off the main actor: hop before touching any state.
            Task { @MainActor in
                guard let self else { return }
                if let text { onText(prefix + text); self.resetSilence() }
                if done { self.stop() }
            }
        }
        state = .listening
        interruption = Self.observeInterruptions { [weak self] in Task { @MainActor in self?.stop() } }
        resetSilence()
    }

    // MARK: System callbacks. These run on queues the system picks (TCC, the audio thread,
    // Speech), so their closures are built in nonisolated code and never inherit the main
    // actor; they only hand plain values back through `@Sendable` closures.

    /// A phone call or another app taking the audio session stops dictation.
    nonisolated private static func observeInterruptions(_ interrupted: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { _ in interrupted() }
    }

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
    }

    /// The tap runs on the audio thread and only appends buffers to the request.
    nonisolated private static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func recognize(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, error != nil || result?.isFinal == true)
        }
    }

    /// Stops listening; called by the glyph, by Send, and after a minute of silence.
    func stop() {
        silence?.cancel(); silence = nil
        if let interruption { NotificationCenter.default.removeObserver(interruption); self.interruption = nil }
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        if state == .listening { state = .idle }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resetSilence() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceLimit)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
}

/// The dictation glyph inside the field: a waveform, or a red pulsing stop while listening.
struct DictationGlyph: View {
    var listening: Bool
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Button(action: action) {
            Image(systemName: listening ? "stop.circle.fill" : "waveform")
                .font(.system(size: Space.glyph, weight: .regular))
                .foregroundStyle(listening ? Color.red : Color.secondary)
                .scaleEffect(listening && pulse && !reduceMotion ? 1.12 : 1)
                .frame(width: Space.glyph + Space.gap, height: Space.fieldHeight)
                .contentShape(Rectangle().inset(by: -Space.tight))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? "Stop Dictation" : "Dictate")
        .onChange(of: listening) { _, value in
            guard value, !reduceMotion else { pulse = false; return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
