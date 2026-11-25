import AVFoundation
import Speech

enum SpeechInputError: Error {
    case noInput
}

/// Hands microphone buffers to whichever recognition request is active. Runs on the audio thread.
private final class AudioSink {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ newValue: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = newValue
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }
}

/// The engine keeps running for the whole drive, because iOS refuses to start recording while the
/// app is in the background. Only the recognition requests come and go.
@MainActor
final class SpeechInput {
    let engine = AVAudioEngine()
    private static let hardCapNanos: UInt64 = 50_000_000_000

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "he-IL"))
    private let sink = AudioSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String?, Never>?
    private var latest = ""
    private var silence: TimeInterval = 1.2
    private var timer: Task<Void, Never>?
    private var cap: Task<Void, Never>?

    func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechInputError.noInput }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(sink))
        engine.prepare()
        try engine.start()
    }

    func restartEngine() throws {
        engine.stop()
        try startEngine()
    }

    func stopEngine() {
        cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private nonisolated static func makeTap(_ sink: AudioSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }

    /// One spoken phrase, or nil if nothing was said within `maxWait` seconds.
    func listen(maxWait: TimeInterval, silence: TimeInterval = 1.2) async -> String? {
        finish()
        guard let recognizer, recognizer.isAvailable, engine.isRunning else { return nil }
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        // Keeps idle car audio on the phone whenever iOS can recognize Hebrew offline.
        if recognizer.supportsOnDeviceRecognition { newRequest.requiresOnDeviceRecognition = true }
        request = newRequest
        latest = ""
        self.silence = silence
        sink.set(newRequest)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<String?, Never>) in
                continuation = waiter
                task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let isFinal = result?.isFinal ?? false
                    let failed = error != nil
                    Task { @MainActor [weak self] in
                        self?.update(text: text, isFinal: isFinal, failed: failed)
                    }
                }
                arm(after: maxWait)
                cap = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.hardCapNanos)
                    guard !Task.isCancelled else { return }
                    self?.finish()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        latest = ""
        finish()
    }

    private func update(text: String?, isFinal: Bool, failed: Bool) {
        guard continuation != nil else { return }
        if let text, !text.isEmpty {
            latest = text
            arm(after: silence)
        }
        if isFinal || failed { finish() }
    }

    private func arm(after seconds: TimeInterval) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        guard let waiter = continuation else { return }
        continuation = nil
        timer?.cancel()
        cap?.cancel()
        sink.set(nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        waiter.resume(returning: text.isEmpty ? nil : text)
    }
}
