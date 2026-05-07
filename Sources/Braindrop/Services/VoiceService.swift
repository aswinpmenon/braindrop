import AVFoundation
import Speech
import Combine

/// Listens to the microphone, streams live speech-to-text, and fires
/// `onFinalTranscript` after the user finishes speaking.
///
/// Silence detection uses TWO independent signals — whichever is most recent wins:
///   1. Transcript change  — new words from the recogniser
///   2. Volume activity    — raw RMS above a noise floor (catches speech the
///                           recogniser hasn't processed yet)
/// The timer only starts after the FIRST word arrives, and only fires when
/// BOTH signals have been quiet for `silenceTimeout` seconds.
@MainActor
class VoiceService: ObservableObject {
    static let shared = VoiceService()

    // MARK: - Published state

    @Published private(set) var isListening:    Bool  = false
    @Published private(set) var transcript:     String = ""
    @Published private(set) var volumeLevel:    Float  = 0    // 0..1 for waveform UI
    @Published private(set) var permissionStatus: PermissionStatus = .unknown

    enum PermissionStatus { case unknown, granted, denied }

    /// Called when silence is detected and transcript is non-empty.
    var onFinalTranscript: ((String) -> Void)?

    // MARK: - Tuning knobs

    /// Seconds of joint audio+transcript silence before auto-submit.
    private let silenceTimeout: TimeInterval = 2.4

    /// RMS level above which audio counts as "active speech".
    private let speechVolumeFloor: Float = 0.04

    // MARK: - Private state

    private var recognizer:        SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask:   SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Timestamp of the last transcript change.
    private var lastTranscriptActivity = Date.distantPast
    /// Timestamp of the last audio frame that exceeded the speech floor.
    private var lastVoiceActivity      = Date.distantPast
    /// Whether any words have been received yet (silence timer only arms after first word).
    private var hasSpoken = false

    private var silenceCheckTimer: Timer?

    private init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let micOK = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        guard micOK else { permissionStatus = .denied; return false }

        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        let ok = speechStatus == .authorized
        permissionStatus = ok ? .granted : .denied
        return ok
    }

    // MARK: - Start / stop

    func startListening() {
        guard !isListening else { return }
        guard permissionStatus == .granted else {
            Task { if await requestPermissions() { self.startListening() } }
            return
        }
        do {
            try beginSession()
            isListening = true
            transcript  = ""
            hasSpoken   = false
            lastTranscriptActivity = Date.distantPast
            lastVoiceActivity      = Date.distantPast
        } catch {
            print("[VoiceService] start error: \(error)")
        }
    }

    func stopListening(submit: Bool = false) {
        guard isListening else { return }
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil
        recognitionTask?.finish()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask    = nil
        isListening = false
        volumeLevel = 0
        if submit, !transcript.trimmingCharacters(in: .whitespaces).isEmpty {
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
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            request.append(buf)

            // Compute RMS
            guard let channelData = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += channelData[i] * channelData[i] }
            let rms = sqrtf(sum / Float(max(n, 1)))
            let level = min(rms * 14, 1.0)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.volumeLevel = level
                // Track last moment audio was loud enough to be speech
                if rms > self.speechVolumeFloor {
                    self.lastVoiceActivity = Date()
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript {
                        self.transcript = text
                        self.lastTranscriptActivity = Date()
                        // Arm the silence checker the moment first words appear
                        if !self.hasSpoken {
                            self.hasSpoken = true
                            self.startSilenceChecker()
                        }
                    }
                    if result.isFinal { self.stopListening(submit: true) }
                }

                if let error {
                    let e = error as NSError
                    // 1110 = recognition cancelled — happens on manual stop, ignore it
                    if e.code != 1110 {
                        print("[VoiceService] recognition error: \(error)")
                        self.stopListening(submit: !self.transcript.isEmpty)
                    }
                }
            }
        }
    }

    /// A repeating timer (every 0.3 s) that fires only after first speech is detected.
    /// It stops listening when BOTH the transcript AND the audio have been silent
    /// for `silenceTimeout` seconds.
    private func startSilenceChecker() {
        silenceCheckTimer?.invalidate()
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening, self.hasSpoken else { return }
                let now = Date()
                let transcriptSilence = now.timeIntervalSince(self.lastTranscriptActivity)
                let voiceSilence      = now.timeIntervalSince(self.lastVoiceActivity)
                // Both signals must be quiet for the full timeout
                if transcriptSilence >= self.silenceTimeout && voiceSilence >= self.silenceTimeout {
                    self.stopListening(submit: true)
                }
            }
        }
    }
}
