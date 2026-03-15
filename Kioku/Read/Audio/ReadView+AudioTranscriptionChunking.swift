import AVFoundation
import SwiftUI

extension ReadView {
    // Detects speech-active regions by adaptive energy thresholding and returns chunk ranges tailored for recognition.
    nonisolated static func makeSpeechActiveChunkRanges(for fileURL: URL, maxChunkDuration: TimeInterval, overlap: TimeInterval) async throws -> [(start: TimeInterval, end: TimeInterval)] {
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No audio track is available for speech activity detection."]
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Could not prepare audio reader output for speech activity detection."]
            )
        }

        reader.add(output)
        guard reader.startReading() else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Could not start reading audio for speech activity detection."]
            )
        }

        var frameEnergies: [Double] = []
        var frameStarts: [TimeInterval] = []
        var frameDurations: [TimeInterval] = []

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            defer {
                CMSampleBufferInvalidate(sampleBuffer)
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

            var dataLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let pointerStatus = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &dataLength,
                dataPointerOut: &dataPointer
            )
            guard pointerStatus == kCMBlockBufferNoErr, let dataPointer, dataLength > 0 else {
                continue
            }

            let sampleCount = dataLength / MemoryLayout<Float>.size
            guard sampleCount > 0 else {
                continue
            }

            let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            var energySum: Double = 0
            for sampleIndex in 0..<sampleCount {
                let sample = Double(floatPointer[sampleIndex])
                energySum += sample * sample
            }

            let meanSquare = energySum / Double(sampleCount)
            let frameEnergy = sqrt(meanSquare)
            let presentationStart = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let presentationDuration = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
            if presentationStart.isFinite == false || presentationDuration.isFinite == false || presentationDuration <= 0 {
                continue
            }

            frameEnergies.append(frameEnergy)
            frameStarts.append(presentationStart)
            frameDurations.append(presentationDuration)
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "Kioku.AudioTranscription",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Audio reader failed during speech activity detection."]
            )
        }

        guard frameEnergies.isEmpty == false else {
            return []
        }

        let sortedEnergies = frameEnergies.sorted()
        let baselineIndex = min(sortedEnergies.count - 1, max(0, Int(Double(sortedEnergies.count - 1) * 0.2)))
        let baselineEnergy = sortedEnergies[baselineIndex]
        let adaptiveThreshold = max(0.002, baselineEnergy * 2.6)

        let averageFrameDuration = frameDurations.reduce(0, +) / Double(frameDurations.count)
        let minActiveFrames = max(1, Int(0.30 / max(averageFrameDuration, 0.001)))
        let hangoverFrames = max(1, Int(0.20 / max(averageFrameDuration, 0.001)))

        var speechRegions: [(start: TimeInterval, end: TimeInterval)] = []
        var activeStartIndex: Int?
        var belowThresholdRunLength = 0

        for frameIndex in 0..<frameEnergies.count {
            let isActiveFrame = frameEnergies[frameIndex] >= adaptiveThreshold

            if isActiveFrame {
                if activeStartIndex == nil {
                    activeStartIndex = frameIndex
                }
                belowThresholdRunLength = 0
                continue
            }

            guard let startIndex = activeStartIndex else {
                continue
            }

            belowThresholdRunLength += 1
            if belowThresholdRunLength < hangoverFrames {
                continue
            }

            let endIndex = max(startIndex, frameIndex - belowThresholdRunLength)
            if endIndex - startIndex + 1 >= minActiveFrames {
                let startTime = frameStarts[startIndex]
                let endTime = frameStarts[endIndex] + frameDurations[endIndex]
                speechRegions.append((start: startTime, end: endTime))
            }
            activeStartIndex = nil
            belowThresholdRunLength = 0
        }

        if let startIndex = activeStartIndex {
            let endIndex = frameEnergies.count - 1
            if endIndex - startIndex + 1 >= minActiveFrames {
                let startTime = frameStarts[startIndex]
                let endTime = frameStarts[endIndex] + frameDurations[endIndex]
                speechRegions.append((start: startTime, end: endTime))
            }
        }

        if speechRegions.isEmpty {
            return []
        }

        var mergedRegions: [(start: TimeInterval, end: TimeInterval)] = []
        let mergeGap: TimeInterval = 0.35
        for region in speechRegions {
            if let lastRegion = mergedRegions.last, region.start - lastRegion.end <= mergeGap {
                mergedRegions[mergedRegions.count - 1] = (start: lastRegion.start, end: max(lastRegion.end, region.end))
            } else {
                mergedRegions.append(region)
            }
        }

        let safeChunkDuration = max(4.0, maxChunkDuration)
        let safeOverlap = min(max(0, overlap), safeChunkDuration - 0.5)
        let step = safeChunkDuration - safeOverlap
        var chunkRanges: [(start: TimeInterval, end: TimeInterval)] = []

        for region in mergedRegions {
            var cursor = max(0, region.start - 0.08)
            let regionEnd = region.end + 0.08
            while cursor < regionEnd {
                let chunkEnd = min(cursor + safeChunkDuration, regionEnd)
                if chunkEnd - cursor >= 0.25 {
                    chunkRanges.append((start: cursor, end: chunkEnd))
                }

                if chunkEnd >= regionEnd {
                    break
                }

                cursor += step
            }
        }

        return chunkRanges
    }

    // Splits an audio file into overlapping fixed-duration chunk ranges to improve long-form transcription recall.
    nonisolated static func makeChunkRanges(for fileURL: URL, chunkDuration: TimeInterval, overlap: TimeInterval) async throws -> [(start: TimeInterval, end: TimeInterval)] {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw NSError(
                domain: "Kioku.AudioTranscription",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not determine audio duration for transcription chunking."]
            )
        }

        let safeChunkDuration = max(4.0, chunkDuration)
        let safeOverlap = min(max(0, overlap), safeChunkDuration - 0.5)
        let step = safeChunkDuration - safeOverlap

        var ranges: [(start: TimeInterval, end: TimeInterval)] = []
        var currentStart: TimeInterval = 0
        while currentStart < durationSeconds {
            let currentEnd = min(currentStart + safeChunkDuration, durationSeconds)
            ranges.append((start: currentStart, end: currentEnd))
            if currentEnd >= durationSeconds {
                break
            }

            currentStart += step
        }

        return ranges
    }
}
