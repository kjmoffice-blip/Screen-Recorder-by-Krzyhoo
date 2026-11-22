import Foundation
@preconcurrency import AVFoundation

@main
struct WriterTests {
    static func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw RecorderFailure(message: message) }
    }
    static func pixel(width: Int, height: Int, red: UInt8) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        try require(status == kCVReturnSuccess && pixel != nil, "pixel allocation")
        let buffer = pixel!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height { for x in 0..<width {
            let n = y * stride + x * 4
            base[n] = 45; base[n+1] = 80; base[n+2] = red; base[n+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    static func audio(frame: Int, channels: Int, clockOffset: Double = 0) throws -> CMSampleBuffer {
        let count = 1600
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 2), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, "audio format")
        var values = [Int16]()
        for n in 0..<(count * channels) {
            let sampleIndex = Double(frame * count + n / channels)
            let phase = sampleIndex * (440.0 * 2.0 * Double.pi / 48000.0)
            values.append(Int16(sin(phase) * 10000.0))
        }
        var block: CMBlockBuffer?
        let length = values.count * 2
        try require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr, "audio block")
        try values.withUnsafeBytes { bytes in
            try require(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) == noErr, "audio bytes")
        }
        var sample: CMSampleBuffer?
        let pts = CMTime(seconds: 10 + clockOffset + Double(frame) / 30 + 0.05, preferredTimescale: 48000)
        try require(CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format!, sampleCount: count, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample) == noErr, "audio sample")
        return sample!
    }
    static func main() async {
        do {
            let folder = URL(fileURLWithPath: CommandLine.arguments[1])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let rect = CaptureGeometry.sourceRect(selection: CGRect(x: 20, y: 30, width: 101, height: 81), screenSize: CGSize(width: 800, height: 600))
            try require(rect == CGRect(x: 20, y: 489, width: 101, height: 81), "crop coordinate transform")
            let dimensions = CaptureGeometry.outputSize(rect: rect, scale: 2)
            try require(dimensions == (202, 162), "Retina dimensions")
            let odd = CaptureGeometry.outputSize(rect: rect, scale: 1)
            try require(odd == (102, 82), "even encoder dimensions")
            for source in AudioSource.allCases {
            for (baseName, size, count) in [("full", (640, 360), 30), ("region", (202, 162), 1)] {
                let name = baseName + "-" + source.rawValue
                let url = folder.appendingPathComponent(name + ".mp4")
                let sink = try MovieSink(url: url, width: size.0, height: size.1, audioSource: source)
                for frame in 0..<30 {
                    let audioBuffer = source == .none ? nil : try audio(frame: frame, channels: source == .microphone ? 1 : 2, clockOffset: source == .microphone ? -10 : 0)
                    let buffer = try pixel(width: size.0, height: size.1, red: UInt8(120 + frame))
                    await withCheckedContinuation { continuation in
                        sink.queue.async {
                            if count > 1 || frame == 0 { sink.append(buffer, time: CMTime(value: Int64(300 + frame), timescale: 30)) }
                            if let audioBuffer { sink.appendAudio(audioBuffer, hostPresentationTime: source == .microphone ? CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(audioBuffer), CMTime(seconds: 10, preferredTimescale: 48000)) : nil) }
                            continuation.resume()
                        }
                    }
                    try await Task.sleep(nanoseconds: 33_333_333)
                }
                
                let frames = try await sink.finish()
                let result = try await validateMovie(url, expectsAudio: source != .none)
                try require(result.0 == CGSize(width: size.0, height: size.1), "\(name) dimensions")
                try require(result.1 >= 0.9 && frames > 0, "\(name) duration including static screen")
                if source != .none {
                    let asset = AVURLAsset(url: url)
                    let track = try await asset.loadTracks(withMediaType: .audio).first!
                    let range = try await track.load(.timeRange)
                    let reader = try AVAssetReader(asset: asset)
                    let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
                    reader.add(decoded); try require(reader.startReading(), "decode AAC")
                    var onset: Double?
                    while let sample = decoded.copyNextSampleBuffer(), onset == nil {
                        if let block = CMSampleBufferGetDataBuffer(sample) {
                            let length = CMBlockBufferGetDataLength(block)
                            var bytes = [UInt8](repeating: 0, count: length)
                            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
                            try require(status == noErr, "read PCM")
                            let channels = source == .microphone ? 1 : 2
                            for index in stride(from: 0, to: max(0, length-1), by: 2 * channels) {
                                let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index+1]) << 8)
                                if abs(Int(value)) > 1000 {
                                    onset = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) + Double(index / (2 * channels)) / 48000
                                    break
                                }
                            }
                        }
                    }
                    reader.cancelReading()
                    try require(onset != nil && abs(onset! - 0.05) < 0.025, "decoded signal sync")
                    print("AUDIO ONSET \(name): \(onset!)s (expected 0.05s)")
                    print("AUDIO RANGE \(name): start=\(CMTimeGetSeconds(range.start)) duration=\(CMTimeGetSeconds(range.duration))")
                    try require(CMTimeGetSeconds(range.start) >= 0 && CMTimeGetSeconds(range.start) < 0.075, "audio/video synchronization")
                    try require(sink.audioSamples == 48000, "all audio samples captured")
                }
                print("PASS \(name): \(size.0)x\(size.1) \(result.1)s, decoded beginning/end, audio=\(source.rawValue), frames=\(frames)")
            }
            }
            let missingAudioURL = folder.appendingPathComponent("missing-audio.mp4")
            let missingAudio = try MovieSink(url: missingAudioURL, width: 100, height: 100, audioSource: .microphone)
            let missingPixel = try pixel(width: 100, height: 100, red: 100)
            await withCheckedContinuation { continuation in
                missingAudio.queue.async { missingAudio.append(missingPixel, time: .zero); continuation.resume() }
            }
            do { _ = try await missingAudio.finish(); throw RecorderFailure(message: "missing audio should fail") }
            catch { try require(!FileManager.default.fileExists(atPath: missingAudioURL.path), "missing audio removal") }
            let emptyURL = folder.appendingPathComponent("empty.mp4")
            let empty = try MovieSink(url: emptyURL, width: 100, height: 100)
            do { _ = try await empty.finish(); throw RecorderFailure(message: "empty movie should fail") }
            catch { try require(!FileManager.default.fileExists(atPath: emptyURL.path), "empty movie removal") }
            let cancelledURL = folder.appendingPathComponent("cancelled.mp4")
            let cancelled = try MovieSink(url: cancelledURL, width: 100, height: 100)
            let buffer = try pixel(width: 100, height: 100, red: 100)
            await withCheckedContinuation { continuation in
                cancelled.queue.async { cancelled.append(buffer, time: .zero); continuation.resume() }
            }
            await cancelled.cancel()
            try require(!FileManager.default.fileExists(atPath: cancelledURL.path), "cancelled movie removal")
            print("PASS geometry, empty/cancel cleanup. ALL WRITER TESTS PASSED")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
