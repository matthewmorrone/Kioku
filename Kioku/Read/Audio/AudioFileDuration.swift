import AVFoundation

// Exact length of a local audio file, from its decoded frame count.
// AVAudioPlayer and a default AVURLAsset estimate an MP3's duration from its bitrate when the file
// has no Xing/VBRI header, which puts a VBR song off by minutes (a 4:10 track reads as 5:13).
// Seeking is unaffected; only the reported length is wrong, so every duration comes from here.
enum AudioFileDuration {
    // Returns the file's length in seconds, or nil when it can't be opened or reports no rate.
    static func seconds(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        return Double(file.length) / sampleRate
    }
}
