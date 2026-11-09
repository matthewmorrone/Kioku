import AVFoundation
import CoreVideo
import SwiftUI

// Writes the cast lyric video: 1280×720 H.264 at 10 fps, one drawn frame per word change (repeated
// between changes), with the song's audio re-encoded as AAC alongside, interleaved as it goes so
// the writer never stalls. Everything runs on the main actor because SwiftUI's ImageRenderer does;
// it yields between frames so the app stays responsive.
enum LyricVideoRenderer {
    private static let framesPerSecond = 10
    private static let pixelSize = CGSize(width: 1280, height: 720)

    enum RenderError: Error {
        case cannotStartWriter(String)
        case noAudioTrack
        case frameFailed
        case cancelled
    }

    // Renders `input` as `mode` to `url`, reporting progress 0...1. Throws on failure or cancellation.
    static func render(input: LyricVideoInput, mode: TVCastMode, to url: URL, progress: (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height)
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(pixelSize.width),
            kCVPixelBufferHeightKey as String: Int(pixelSize.height)
        ])
        writer.add(videoInput)

        // The audio side: decoded to PCM by a reader, re-encoded to AAC by the writer.
        let audioAsset = AVURLAsset(url: input.audioURL)
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw RenderError.noAudioTrack }
        let reader = try AVAssetReader(asset: audioAsset)
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(readerOutput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 160_000
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else { throw RenderError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown") }
        guard reader.startReading() else { throw RenderError.cannotStartWriter(reader.error?.localizedDescription ?? "audio reader") }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, input.durationMs * framesPerSecond / 1000)
        var currentBuffer: CVPixelBuffer?
        var currentActive = -1
        var pendingAudio: CMSampleBuffer?
        var audioDone = false
        var frame = 0
        while frame <= totalFrames {
            try Task.checkCancellation()
            let timeMs = frame * 1000 / framesPerSecond
            let active = activeIndex(in: input.words, atMs: timeMs)
            if active != currentActive || currentBuffer == nil {
                currentBuffer = try drawFrame(input: input, mode: mode, active: active, pool: adaptor.pixelBufferPool)
                currentActive = active
            }
            while videoInput.isReadyForMoreMediaData == false {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
            if let buffer = currentBuffer {
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond)))
            }
            // Audio one second ahead of the video keeps the two interleaved.
            let horizon = CMTime(value: CMTimeValue(timeMs + 1000), timescale: 1000)
            while audioDone == false, audioInput.isReadyForMoreMediaData {
                if pendingAudio == nil { pendingAudio = readerOutput.copyNextSampleBuffer() }
                guard let sample = pendingAudio else { audioDone = true; break }
                if CMSampleBufferGetPresentationTimeStamp(sample) > horizon { break }
                audioInput.append(sample)
                pendingAudio = nil
            }
            progress(Double(frame) / Double(totalFrames))
            frame += 1
            await Task.yield()
        }
        videoInput.markAsFinished()
        // Whatever audio remains after the last frame.
        while audioDone == false {
            try Task.checkCancellation()
            guard audioInput.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            guard let sample = pendingAudio ?? readerOutput.copyNextSampleBuffer() else { audioDone = true; break }
            pendingAudio = nil
            audioInput.append(sample)
        }
        audioInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RenderError.cannotStartWriter(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
    }

    // The word being sung at `ms`: the last whose start has passed, the first before any.
    private static func activeIndex(in words: [WordFocusWord], atMs ms: Int) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let mid = (low + high) / 2
            if words[mid].startMs <= ms { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    // Draws one frame view into a pixel buffer from the writer's pool.
    private static func drawFrame(input: LyricVideoInput, mode: TVCastMode, active: Int, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        let renderer = ImageRenderer(content: LyricVideoFrameView(input: input, mode: mode, active: active))
        renderer.proposedSize = ProposedViewSize(LyricVideoFrameView.canvas)
        // The canvas is laid out at 1920×1080 points and rasterised at the video's 1280×720.
        renderer.scale = pixelSize.width / LyricVideoFrameView.canvas.width
        guard let image = renderer.cgImage, let pool else { throw RenderError.frameFailed }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw RenderError.frameFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw RenderError.frameFailed }
        context.draw(image, in: CGRect(origin: .zero, size: pixelSize))
        return buffer
    }
}
