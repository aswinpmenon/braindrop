import AVFoundation
import Speech
import Combine

/// Listens to the microphone, streams live speech-to-text, and fires
/// `onFinalTranscript` after `silenceTimeout` seconds of silence.
@MainActor
class VoiceService: ObservableObject {
    static let shared = VoiceService()

    // MARK: - Published state

    @Published private(set) var isListening  = false
    @Published private(set) var transcript   = ""
    @Published private(set) var volumeLevel: Float = 0   // 0..1 for waveform UI
    @Published private(set) var permissionStatus: PermissionStatus = .unknown

    enum PermissionStatus { case unknown, granted, denied }

    // Called when silence is detected — the ViewModel uses this to auto-submit.
    var onFinalTranscript: ((String) -> Void)?

    // MARK: - Private

    private let silenceTimeout: TimeInterval = 1.6
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var silenceTimer: Timer?
    private var lastTranscript = ""

    private init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        // Microphone
        let micOK = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        guard micOK else { permissionStatus = .denied; return false }

        // Speech
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        let speechOK = speechStatus == .authorized
        permissionStatus = speechOK ? .granted : .denied
        return speechOK
    }

    // MARK: - Start / stop

    func startListening() {
        guard !isListening else { return }
        guard permissionStatus == .granted else {
            Task { if await requestPermissions() { startListening() } }
            return
        }
        do {
            try beginSession()
            isListening  = true
            transcript   = ""
            lastTranscript = ""
        } catch {
            print("[VoiceService] start error: \(error)")
        }
    }

    func stopListening(submit: Bool = false) {
        guard isListening else { return }
        silenceTimer?.invalidate(); silenceTimer = nil
        recognitionTask?.finish()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask    = nil
        isListening  = false
        volumeLevel  = 0
        if submit, !transcript.isEmpty {
            let final = transcript
            onFinalTranscript?(final)
        }
    }

    func toggle() {
        isListening ? stopListening(submit: false) : startListening()
    }

    // MARK: - Internal

    private func beginSession() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Use on-device recognition when available (macOS 13+, no network needed)
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            request.append(buf)
            // Compute RMS for volume meter
            guard let channelData = buf.floatChannelData?[0] else { return }
            let frameCount = Int(buf.frameLength)
            var rms: Float = 0
            for i in 0..<frameCount { rms += channelData[i] * channelData[i] }
            rms = sqrtf(rms / Float(max(frameCount, 1)))
            let level = min(rms * 12, 1.0)   // scale to 0..1
            Task { @MainActor [weak self] in self?.volumeLevel = level }
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.transcript = text
                    if text != self.lastTranscript {
                        self.lastTranscript = text
                        self.resetSilenceTimer()
                    }
                    if result.isFinal {
                        self.stopListening(submit: true)
                    }
                }
                if let error {
                    // Ignore cancellation errors (normal when we stop manually)
                    let nsErr = error as NSError
                    if nsErr.domain != "kAFAssistantErrorDomain" || nsErr.code != 1110 {
                        print("[VoiceService] recognition error: \(error)")
                    }
                    self.stopListening(submit: false)
                }
            }
        }

        // Start silence timer immediately; it resets whenever new words arrive
        resetSilenceTimer()
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                self.stopListening(submit: true)
            }
        }
    }
}
