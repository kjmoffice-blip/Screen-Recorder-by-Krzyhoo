import AppKit
import AVFoundation
import ScreenCaptureKit

struct RecorderFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CaptureGeometry {
    static func sourceRect(selection: CGRect, screenSize: CGSize) -> CGRect {
        CGRect(x: selection.minX, y: screenSize.height - selection.maxY,
               width: selection.width, height: selection.height)
    }
    static func outputSize(rect: CGRect, scale: CGFloat) -> (Int, Int) {
        // H.264 requires even dimensions. Preserve the complete selected rectangle.
        (max(2, Int(ceil(rect.width * scale / 2)) * 2),
         max(2, Int(ceil(rect.height * scale / 2)) * 2))
    }
}

// All mutable writer state belongs to queue; SCStream delivers frames on that queue.
final class MovieSink: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "pl.krzyhoo.screenrecorder.writer")
    let temporaryURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private(set) var audioSamples = 0
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var origin: CMTime?
    private var lastTime = CMTime.zero
    private var lastPixel: CVPixelBuffer?
    private var firstFrameUptime: TimeInterval?
    private var finishing = false
    private var failure: Error?
    private(set) var frames = 0
    var onFailure: ((Error) -> Void)?
    var onFirstFrame: (() -> Void)?

    init(url: URL, width: Int, height: Int, audioSource: AudioSource = .none) throws {
        temporaryURL = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, min(32_000_000, width * height * 5)),
                                              AVVideoExpectedSourceFrameRateKey: 30,
                                              AVVideoMaxKeyFrameIntervalKey: 60]])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw RecorderFailure(message: "Nie można skonfigurować kodera MP4.") }
        writer.add(input)
        if audioSource != .none {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: audioSource == .microphone ? 1 : 2,
                AVEncoderBitRateKey: 128_000])
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw RecorderFailure(message: "Nie można skonfigurować dźwięku AAC.") }
            writer.add(audio); audioInput = audio
        } else { audioInput = nil }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { appendAudio(sampleBuffer); return }
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        append(pixel, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // Called on queue, also exercised by synthetic writer tests.
    func append(_ pixel: CVPixelBuffer, time: CMTime) {
        guard !finishing, failure == nil, time.isValid, time.isNumeric else { return }
        if origin == nil {
            guard writer.startWriting() else { fail(writer.error ?? RecorderFailure(message: "Nie można rozpocząć zapisu MP4.")); return }
            writer.startSession(atSourceTime: .zero)
            origin = time
            firstFrameUptime = ProcessInfo.processInfo.systemUptime
        }
        let relative = CMTimeSubtract(time, origin!)
        guard frames == 0 || CMTimeCompare(relative, lastTime) > 0 else { return }
        guard input.isReadyForMoreMediaData else {
            if writer.status == .failed { fail(writer.error ?? RecorderFailure(message: "Koder zatrzymał zapis.")) }
            return // Drop frames under pressure instead of blocking the capture queue.
        }
        guard adaptor.append(pixel, withPresentationTime: relative) else {
            fail(writer.error ?? RecorderFailure(message: "Nie można zapisać klatki. Sprawdź wolne miejsce w Pobranych.")); return
        }
        lastPixel = pixel
        lastTime = relative
        frames += 1
        if frames == 1 { onFirstFrame?() }
    }

    func appendAudio(_ sample: CMSampleBuffer, hostPresentationTime: CMTime? = nil) {
        guard !finishing, failure == nil, let origin, let audioInput,
              CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample) else { return }
        // Microphone timestamps are converted from its synchronization clock to the host clock.
        // Rebase them to the first video frame so tracks use one shared timeline.
        let pts = hostPresentationTime ?? CMSampleBufferGetPresentationTimeStamp(sample)
        let clockOffset = CMTimeSubtract(pts, CMSampleBufferGetPresentationTimeStamp(sample))
        guard CMTimeCompare(pts, origin) >= 0 else { return }
        guard audioInput.isReadyForMoreMediaData else {
            if writer.status == .failed { fail(writer.error ?? RecorderFailure(message: "Zapis dźwięku został przerwany.")) }
            return
        }
        var count = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr, count > 0 else { fail(RecorderFailure(message: "Nie można odczytać czasu dźwięku.")); return }
        var timings = Array(repeating: CMSampleTimingInfo(), count: count)
        status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        guard status == noErr else { fail(RecorderFailure(message: "Nie można zsynchronizować dźwięku.")); return }
        for i in timings.indices {
            timings[i].presentationTimeStamp = CMTimeSubtract(CMTimeAdd(timings[i].presentationTimeStamp, clockOffset), origin)
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = CMTimeSubtract(CMTimeAdd(timings[i].decodeTimeStamp, clockOffset), origin) }
        }
        var adjusted: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &adjusted)
        guard status == noErr, let adjusted, audioInput.append(adjusted) else {
            fail(writer.error ?? RecorderFailure(message: "Nie można zapisać dźwięku w filmie.")); return
        }
        audioSamples += CMSampleBufferGetNumSamples(sample)
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onFailure?(error)
    }

    func finish() async throws -> Int {
        let stopUptime = ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finishing = true
                guard self.frames > 0, self.failure == nil, self.audioInput == nil || self.audioSamples > 0 else {
                    self.writer.cancelWriting()
                    try? FileManager.default.removeItem(at: self.temporaryURL)
                    continuation.resume(throwing: self.failure ?? RecorderFailure(message: self.frames > 0 ? "Nie odebrano dźwięku z wybranego źródła. Film nie został zapisany; sprawdź mikrofon lub spróbuj trybu Bez dźwięku." : "Nie odebrano żadnej klatki. Film nie został zapisany. Sprawdź zgodę na nagrywanie ekranu i spróbuj ponownie."))
                    return
                }
                // ScreenCaptureKit may send no new frames on a static desktop. End at stop time,
                // not at the last desktop change. Retry asynchronously while encoder drains.
                let elapsed = stopUptime - (self.firstFrameUptime ?? stopUptime)
                let end = max(elapsed, CMTimeGetSeconds(self.lastTime) + 1.0 / 30.0)
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                self.appendFinalFrame(end: CMTime(seconds: end, preferredTimescale: 600), deadline: deadline, continuation: continuation)
            }
        }
    }

    private func appendFinalFrame(end: CMTime, deadline: TimeInterval, continuation: CheckedContinuation<Int, Error>) {
        guard writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temporaryURL)
            continuation.resume(throwing: writer.error ?? RecorderFailure(message: "Zapis filmu został przerwany."))
            return
        }
        if !input.isReadyForMoreMediaData {
            if ProcessInfo.processInfo.systemUptime < deadline {
                queue.asyncAfter(deadline: .now() + 0.02) { self.appendFinalFrame(end: end, deadline: deadline, continuation: continuation) }
            } else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: temporaryURL)
                continuation.resume(throwing: RecorderFailure(message: "Koder nie zakończył filmu w wymaganym czasie."))
            }
            return
        }
        guard let pixel = lastPixel, adaptor.append(pixel, withPresentationTime: end) else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temporaryURL)
            continuation.resume(throwing: writer.error ?? RecorderFailure(message: "Nie można zakończyć filmu."))
            return
        }
        input.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTimeAdd(end, CMTime(value: 1, timescale: 30)))
        writer.finishWriting {
            if self.writer.status == .completed { continuation.resume(returning: self.frames) }
            else {
                try? FileManager.default.removeItem(at: self.temporaryURL)
                continuation.resume(throwing: self.writer.error ?? RecorderFailure(message: "Nie udało się zamknąć filmu MP4."))
            }
        }
    }

    func cancel() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finishing = true
                self.writer.cancelWriting()
                try? FileManager.default.removeItem(at: self.temporaryURL)
                continuation.resume()
            }
        }
    }
}

func validateMovie(_ url: URL, expectsAudio: Bool = false) async throws -> (CGSize, Double) {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let videos = try await asset.loadTracks(withMediaType: .video)
    let audios = try await asset.loadTracks(withMediaType: .audio)
    guard let track = videos.first, (expectsAudio ? !audios.isEmpty : audios.isEmpty), CMTimeGetSeconds(duration) > 0 else {
        throw RecorderFailure(message: "Film nie zawiera poprawnego obrazu.")
    }
    if expectsAudio, let audioTrack = audios.first {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        guard reader.startReading(), output.copyNextSampleBuffer() != nil else { throw RecorderFailure(message: "Film nie zawiera poprawnego dźwięku.") }
        reader.cancelReading()
    }
    let size = try await track.load(.naturalSize)
    let generator = AVAssetImageGenerator(asset: asset)
    _ = try generator.copyCGImage(at: .zero, actualTime: nil)
    _ = try generator.copyCGImage(at: CMTimeMultiplyByFloat64(duration, multiplier: 0.8), actualTime: nil)
    return (size, CMTimeGetSeconds(duration))
}
