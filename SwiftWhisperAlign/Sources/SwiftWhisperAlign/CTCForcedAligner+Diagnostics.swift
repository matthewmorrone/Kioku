import Foundation
import AVFoundation

// On-device diagnostics for an alignment run, kept out of the algorithm file.
extension CTCForcedAligner {
    // Writes a timestamped breadcrumb + remaining memory budget to <Documents>/ctc-debug.log.
    // Flushed on every call, so if the OS kills the app mid-run the LAST line names the stage
    // that was running and the availMem trend shows whether memory was the cause. Best-effort;
    // never throws. `reset:true` starts a fresh log for the run.
    static func breadcrumb(_ stage: String, reset: Bool = false) {
        #if os(iOS)
        let availMB = Int(os_proc_available_memory()) / (1024 * 1024)
        #else
        let availMB = -1
        #endif
        let line = "[\(Date())] \(stage) | availMem=\(availMB)MB\n"
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = line.data(using: .utf8) else { return }
        let url = dir.appendingPathComponent("ctc-debug.log")
        if reset || FileManager.default.fileExists(atPath: url.path) == false {
            try? data.write(to: url)
        } else if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    // Writes mono float samples to <Documents>/<name> as a 16-bit PCM WAV so the isolated vocal
    // stem can be played from Files → On My iPhone → Kioku (the app has UIFileSharingEnabled) to
    // judge isolation quality. DEBUG-only at the call site: it's a ~19 MB write per align.
    static func saveDebugWAV(_ samples: [Float], sampleRate: Double, name: String) {
        guard samples.isEmpty == false,
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: samples.count) }
        try? file.write(from: buf)
    }
}
