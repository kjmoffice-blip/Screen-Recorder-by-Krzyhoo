import AVFoundation

// Exactly one source is active; no microphone/system mixing.
enum AudioSource: String, CaseIterable {
    case none, system, microphone
    var title: String {
        switch self {
        case .none: return "Bez dźwięku"
        case .system: return "Dźwięk z komputera"
        case .microphone: return "Mikrofon"
        }
    }
}

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let controlQueue = DispatchQueue(label: "pl.krzyhoo.screenrecorder.microphone")
    private let sink: MovieSink
    static func requestPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default: break
        }
        throw RecorderFailure(message: "Brak zgody na mikrofon. Włącz Screen Recorder by Krzyhoo w Ustawieniach systemowych → Prywatność i ochrona → Mikrofon, albo wybierz inne źródło dźwięku.")
    }
    init(sink: MovieSink) throws {
        self.sink = sink
        super.init()
        guard let device = AVCaptureDevice.default(for: .audio) else { throw RecorderFailure(message: "Nie znaleziono mikrofonu. Sprawdź urządzenie wejściowe w ustawieniach Dźwięk.") }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { throw RecorderFailure(message: "Nie można uruchomić wybranego mikrofonu.") }
        session.addInput(input); session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: sink.queue)
    }
    func start() async {
        await withCheckedContinuation { continuation in
            controlQueue.async { self.session.startRunning(); continuation.resume() }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            controlQueue.async { self.session.stopRunning(); continuation.resume() }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else { return }
        let hostPTS = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock, to: CMClockGetHostTimeClock())
        sink.appendAudio(sampleBuffer, hostPresentationTime: hostPTS)
    }
}
