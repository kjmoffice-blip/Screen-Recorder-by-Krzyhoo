import Foundation
import AVFoundation
import AppKit

@main struct MovieProbe {
    static func main() async {
        do {
            let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            let duration = try await asset.load(.duration)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let size = try await video[0].load(.naturalSize)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            _ = try imageGenerator.copyCGImage(at: .zero, actualTime: nil)
            _ = try imageGenerator.copyCGImage(at: CMTimeMultiplyByFloat64(duration, multiplier: 0.9), actualTime: nil)
            print("DECODE beginning/end: PASS")
            print("VIDEO \(Int(size.width))x\(Int(size.height)) duration=\(CMTimeGetSeconds(duration)) videoTracks=\(video.count) audioTracks=\(audio.count)")
            if let track = audio.first {
                let timeRange = try await track.load(.timeRange)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
                reader.add(output)
                guard reader.startReading() else { throw reader.error! }
                var samples = 0; var energy = 0.0; var peak = 0
                while let sample = output.copyNextSampleBuffer() {
                    if let block = CMSampleBufferGetDataBuffer(sample) {
                        let count = CMBlockBufferGetDataLength(block)
                        var bytes = [UInt8](repeating: 0, count: count)
                        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: &bytes) == noErr else { throw NSError(domain: "PCM", code: 1) }
                        for i in stride(from: 0, to: count - 1, by: 2) {
                            let value = Int(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8))
                            energy += Double(value * value); samples += 1; peak = max(peak, abs(value))
                        }
                    }
                }
                guard reader.status == .completed else { throw reader.error ?? NSError(domain: "decode", code: 1) }
                print("AUDIO decodedSamples=\(samples) RMS=\(sqrt(energy / Double(max(1, samples))) / 32768) peak=\(Double(peak) / 32768) start=\(CMTimeGetSeconds(timeRange.start)) duration=\(CMTimeGetSeconds(timeRange.duration))")
            }
            if CommandLine.arguments.count > 2 {
                let generator = AVAssetImageGenerator(asset: asset)
                let cg = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
                let rep = NSBitmapImageRep(cgImage: cg)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            }
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
