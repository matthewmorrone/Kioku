import AVFoundation
import Foundation

// Microphone capture for Sing mode: taps the audio engine's input, converts to 16 kHz mono and
// feeds SingAudioRing with each buffer's capture time. Nothing is written to disk.
nonisolated final class SingMicCapture: @unchecked Sendable {
    let ring = SingAudioRing()
    // Created per start: an engine made before the session allowed recording keeps a dead input.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    // Read on the tap thread: while false (paused) incoming audio is dropped.
    private let acceptLock = NSLock()
    private var acceptingAudio = false

    // Starts the input tap. The audio session must already allow recording (playAndRecord).
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let detail = "input \(Int(inFormat.sampleRate)) Hz × \(inFormat.channelCount), available \(session.isInputAvailable), category \(session.category.rawValue)"
        AppLog.info(.audioPlayback, "[Sing] mic start: \(detail)")
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SingAudioRing.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "Kioku.Sing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable (\(detail))."])
        }
        self.engine = engine
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, when in
            self?.handle(buffer: buffer, when: when, outFormat: outFormat)
        }
        engine.prepare()
        try engine.start()
    }

    // Removes the tap and stops the engine.
    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        ring.reset()
    }

    // Gates capture on playback: audio heard while paused has no song time to pin to.
    func setAccepting(_ accepting: Bool) {
        acceptLock.lock(); acceptingAudio = accepting; acceptLock.unlock()
        if accepting == false { ring.reset() }
    }

    // Converts one input buffer to 16 kHz mono and stamps it with the host time its last sample
    // was captured (buffer start + its duration, less the input route's latency).
    private func handle(buffer: AVAudioPCMBuffer, when: AVAudioTime, outFormat: AVAudioFormat) {
        acceptLock.lock(); let accepting = acceptingAudio; acceptLock.unlock()
        guard accepting, let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            AppLog.error(.audioPlayback, "[Sing] mic convert failed: \(error.localizedDescription)")
            return
        }
        guard let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        let startSec = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let newest = startSec + Double(buffer.frameLength) / buffer.format.sampleRate - AVAudioSession.sharedInstance().inputLatency
        ring.append(chunk, newestHostSec: newest)
    }
}
