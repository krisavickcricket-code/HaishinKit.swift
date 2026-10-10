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
    /// The anchor, expressed as durations rather than absolute positions:
    /// the mach wall reading taken when the anchor was set and the timeline's
    /// sample position at the anchor. Together they define where the timeline
    /// *should* sit had it advanced at wall-clock rate ever since — the
    /// reference for detecting outages the capture clock never reported.
    private var anchorMachSeconds: Double = 0
    private var anchorSampleTime: AVAudioFramePosition = 0

    /// Current mach absolute time in seconds. Deliberately independent of
    /// AVAudioTime's conversion conveniences, which changed shape across SDKs
    /// (the static `seconds` accessor lost its `forHostTime:` label and the
    /// instance property in recent SDKs) — a local timebase calculation is
    /// stable on every toolchain.
    static func machWallSeconds() -> Double {
        var timebase = mach_timebase_info_data_t()
        _ = mach_timebase_info(&timebase)
        return Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Signed seconds the timeline trails (positive) or leads (negative) a
    /// wall-clock-rate advance since the anchor: wall time elapsed minus
    /// timeline seconds advanced. Pure duration math inside the timeline's
    /// own anchor domain — the domain is deliberately preserved, because
    /// re-anchoring onto mach epoch seconds would corrupt a timeline the
    /// capture PTS anchored at a counter-relative zero. Nil while unanchored.
    func wallRateLagSeconds(nowMachSeconds: Double) -> Double? {
        guard 0 < sampleRate, 0 < anchorMachSeconds, anchorTime != nil else {
            return nil
        }
        let elapsedWall = nowMachSeconds - anchorMachSeconds
        let advancedTimeline = Double(sampleTime - anchorSampleTime) / sampleRate
        return elapsedWall - advancedTimeline
    }

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
        anchorMachSeconds = AudioTime.machWallSeconds()
        anchorSampleTime = sampleTime
        anchorTime = .init(hostTime: AVAudioTime.hostTime(forSeconds: time.seconds), sampleTime: sampleTime, atRate: sampleRate)
    }

    func anchor(_ time: AVAudioTime) {
        guard anchorTime == nil else {
            return
        }
        sampleRate = time.sampleRate
        sampleTime = 0
        anchorMachSeconds = AudioTime.machWallSeconds()
        anchorSampleTime = sampleTime
        anchorTime = time
    }

    func reset() {
        sampleRate = 0.0
        sampleTime = 0
        anchorTime = nil
        anchorMachSeconds = 0
        anchorSampleTime = 0
    }
}
