import AVFoundation
import Foundation

/// A helper class for interoperating between AVAudioTime and CMTime.
/// Conversion fails without hostTime on the AVAudioTime side, and cannot be saved with AVAssetWriter.
final class AudioTime {
    var at: AVAudioTime {
        let now = AVAudioTime(sampleTime: sampleTime, atRate: sampleRate)
        guard let anchorTime else {
            return now
        }
        return now.extrapolateTime(fromAnchor: anchorTime) ?? now
    }

    var hasAnchor: Bool {
        return anchorTime != nil
    }

    private var sampleRate: Double = 0.0
    private var anchorTime: AVAudioTime?
    private var sampleTime: AVAudioFramePosition = 0

    func advanced(_ count: AVAudioFramePosition) {
        sampleTime += count
    }

    /// Advances the timeline by a duration rather than a frame count — used to
    /// step over a microphone outage that the capture timeline did not report,
    /// so audio after the outage keeps its true wall-clock position.
    func advanced(seconds: Double) {
        guard 0 < sampleRate else {
            return
        }
        sampleTime += AVAudioFramePosition(seconds * sampleRate)
    }

    func anchor(_ time: CMTime, sampleRate: Double) {
        guard anchorTime == nil else {
            return
        }
        self.sampleRate = sampleRate
        if time.timescale == Int32(sampleRate) {
            sampleTime = time.value
        } else {
            // ReplayKit .appAudio
            sampleTime = Int64(Double(time.value) * sampleRate / Double(time.timescale))
        }
        anchorTime = .init(hostTime: AVAudioTime.hostTime(forSeconds: time.seconds), sampleTime: sampleTime, atRate: sampleRate)
    }

    func anchor(_ time: AVAudioTime) {
        guard anchorTime == nil else {
            return
        }
        sampleRate = time.sampleRate
        sampleTime = 0
        anchorTime = time
    }

    func reset() {
        sampleRate = 0.0
        sampleTime = 0
        anchorTime = nil
    }
}
