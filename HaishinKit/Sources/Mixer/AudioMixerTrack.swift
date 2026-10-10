import Accelerate
import AVFoundation

private let kIOAudioMixerTrack_frameCapacity: AVAudioFrameCount = 1024

/// Timeline-vs-wall tolerance before a wall re-anchor is even considered.
/// Ordinary capture->render latency and ring-buffer hold stay well below
/// this at steady state; an un-owned outage (mic dead air the capture clock
/// never reported — a phone call under DND-off, a mic route flap, silence
/// delivered across an interruption) shows up as a lag that grows with the
/// outage and never recovers on its own, because the capture PTS continue
/// seamlessly from a clock that froze with the mic.
private let kWallReanchorEpsilonSeconds: Double = 0.15

/// A lag must persist this long in wall time before the re-anchor fires.
/// A late-delivery burst (audio captured through a CPU stall, delivered
/// late with content intact) also measures as lag while it drains — but
/// the burst completes within milliseconds, so by the time the settle
/// window elapses its own delivered samples have erased the lag and the
/// guard fails. A real outage's lag never drains (the capture clock froze
/// with the mic; there is nothing coming to fill the gap), so it survives
/// the window and the repair fires about half a second after content
/// resumes.
private let kWallReanchorSettleSeconds: Double = 0.5

/// Read-only facts about the audio output timeline's health. The output
/// timeline is the single stamp authority for everything downstream —
/// recordings (AVAssetWriter) and streams (RTMP) both stamp from it — so any
/// displacement it accumulates shows up as audio out of sync with video in
/// every surface at once.
public struct AudioTimelineTelemetry: Sendable {
    /// Signed seconds the timeline moved on the most recent wall re-anchor.
    /// Positive = advanced to close a trailing lag, negative = pulled back.
    public let lastWallReanchorSeconds: Double
    /// Signed sum of every wall re-anchor since the track was born.
    public let totalWallReanchorSeconds: Double
    /// Number of wall re-anchors since the track was born.
    public let wallReanchorCount: Int
    /// Signed sum of the capture-outage jumps mirrored from the ring buffer.
    public let totalClockJumpSeconds: Double
}

protocol AudioMixerTrackDelegate: AnyObject {
    func track(_ track: AudioMixerTrack<Self>, didOutput audioPCMBuffer: AVAudioPCMBuffer, when: AVAudioTime)
    func track(_ track: AudioMixerTrack<Self>, errorOccurred error: AudioMixerError)
}

/// Constraints on the audio mixier track's settings.
public struct AudioMixerTrackSettings: Codable, Sendable {
    /// The default value.
    public static let `default` = AudioMixerTrackSettings()

    /// Specifies the volume for output.
    public var volume: Float

    /// Specifies the muted that indicates whether the audio output is muted.
    public var isMuted = false

    /// Specifies the mixes the channels or not. Currently, it supports input sources with 4, 5, 6, and 8 channels.
    public var downmix = true

    /// Specifies the map of the output to input channels.
    /// ## Example code:
    /// ```
    /// // If you want to use the 3rd and 4th channels from a 4-channel input source for a 2-channel output, you would specify it like this.
    /// channelMap = [2, 3]
    /// ```
    public var channelMap: [Int]?

    /// Creates a new instance.
    public init(volume: Float = 1.0, isMuted: Bool = false, downmix: Bool = true, channelMap: [Int]? = nil) {
        self.volume = volume
        self.isMuted = isMuted
        self.downmix = downmix
        self.channelMap = channelMap
    }

    func apply(_ converter: AVAudioConverter?, oldValue: AudioMixerTrackSettings?) {
        guard let converter else {
            return
        }
        if converter.downmix != downmix {
            converter.downmix = downmix
        }
        if let channelMap = validatedChannelMap(converter) {
            converter.channelMap = channelMap.map { NSNumber(value: $0) }
        } else {
            switch converter.outputFormat.channelCount {
            case 1:
                converter.channelMap = [0]
            case 2:
                converter.channelMap = (converter.inputFormat.channelCount == 1) ? [0, 0] : [0, 1]
            default:
                break
            }
        }
    }

    private func validatedChannelMap(_ converter: AVAudioConverter) -> [Int]? {
        guard let channelMap, channelMap.count == converter.outputFormat.channelCount else {
            return nil
        }
        for inputChannel in channelMap where converter.inputFormat.channelCount <= inputChannel {
            return nil
        }
        return channelMap
    }
}

final class AudioMixerTrack<T: AudioMixerTrackDelegate> {
    let id: UInt8
    let outputFormat: AVAudioFormat

    var settings: AudioMixerTrackSettings = .init() {
        didSet {
            settings.apply(audioConverter, oldValue: oldValue)
        }
    }
    weak var delegate: T?

    var inputFormat: AVAudioFormat? {
        return audioConverter?.inputFormat
    }
    private var inSourceFormat: CMFormatDescription? {
        didSet {
            guard inSourceFormat != oldValue else {
                return
            }
            setUp(inSourceFormat)
        }
    }
    private var audioTime = AudioTime()
    private var ringBuffer: AudioRingBuffer?
    private var inputBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var audioConverter: AVAudioConverter? {
        didSet {
            guard let audioConverter else {
                return
            }
            settings.apply(audioConverter, oldValue: nil)
            audioConverter.primeMethod = .normal
        }
    }

    // MARK: - Wall re-anchor

    private var wallLagFirstSeenMachSeconds: Double = 0

    private let telemetryLock = NSLock()
    private var _lastWallReanchorSeconds: Double = 0
    private var _totalWallReanchorSeconds: Double = 0
    private var _wallReanchorCount = 0
    private var _totalClockJumpSeconds: Double = 0

    /// Current audio-timeline telemetry. Safe to read from any queue; the
    /// append path runs on the capture callback queue.
    var audioTimelineTelemetry: AudioTimelineTelemetry {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }
        return AudioTimelineTelemetry(
            lastWallReanchorSeconds: _lastWallReanchorSeconds,
            totalWallReanchorSeconds: _totalWallReanchorSeconds,
            wallReanchorCount: _wallReanchorCount,
            totalClockJumpSeconds: _totalClockJumpSeconds
        )
    }

    private func recordWallReanchor(_ seconds: Double) {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }
        _lastWallReanchorSeconds = seconds
        _totalWallReanchorSeconds += seconds
        _wallReanchorCount += 1
    }

    private func recordClockJump(_ seconds: Double) {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }
        _totalClockJumpSeconds += seconds
    }

    /// Re-anchors the output timeline onto wall-clock rate whenever it trails
    /// (or leads) wall time by more than the tolerance and the ring does not
    /// already own the gap. This is the catch-all for outages the capture
    /// clock never reports: the capture PTS keep advancing seamlessly on a
    /// clock that froze with the mic, so neither the ring's PTS-gap logic nor
    /// the delivery-lateness jump can see the gap — only the wall can. The
    /// correction moves the timeline forward inside its own anchor domain
    /// (stamps jump forward as a gap; downstream writers keep the hole rather
    /// than shifting audio early), leaving audio after the outage at its true
    /// wall-clock position relative to video.
    private func applyWallReanchor() {
        lastWallReanchorReset()
        guard audioTime.hasAnchor, let ringBuffer else {
            return
        }
        let wallNow = AudioTime.machWallSeconds()
        guard let lag = audioTime.wallRateLagSeconds(nowMachSeconds: wallNow) else {
            return
        }
        // Timeline seconds the ring still owes or holds — silence-fill debt
        // plus buffered input. A lag the ring will fill (captured content en
        // route, a PTS-reported gap awaiting starvation) is owned and must
        // never trigger a correction.
        let owed = ringBuffer.owedSeconds
        let effectiveLag = lag - owed
        if kWallReanchorEpsilonSeconds < effectiveLag {
            if wallLagFirstSeenMachSeconds == 0 {
                wallLagFirstSeenMachSeconds = wallNow
            }
            guard kWallReanchorSettleSeconds <= wallNow - wallLagFirstSeenMachSeconds else {
                return
            }
            wallLagFirstSeenMachSeconds = 0
            let correction = effectiveLag
            audioTime.advanced(seconds: correction)
            recordWallReanchor(correction)
        } else {
            wallLagFirstSeenMachSeconds = 0
            guard effectiveLag < -kWallReanchorEpsilonSeconds else {
                return
            }
            // The timeline ran into the future (a misfired jump). Pull it back
            // to wall: the few stamps ahead of reality get bounded and loudly
            // counted, which beats leaving audio permanently early.
            let correction = effectiveLag
            audioTime.advanced(seconds: correction)
            recordWallReanchor(correction)
        }
    }

    @inline(__always)
    private func lastWallReanchorReset() {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }
        _lastWallReanchorSeconds = 0
    }

    init(id: UInt8, outputFormat: AVAudioFormat) {
        self.id = id
        self.outputFormat = outputFormat
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        inSourceFormat = sampleBuffer.formatDescription
        if !audioTime.hasAnchor {
            audioTime.anchor(sampleBuffer.presentationTimeStamp, sampleRate: outputFormat.sampleRate)
        }
        ringBuffer?.append(sampleBuffer)
        applyOutageClockJump()
        applyWallReanchor()
        resample()
    }

    func append(_ audioBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        inSourceFormat = audioBuffer.format.formatDescription
        if !audioTime.hasAnchor {
            audioTime.anchor(when)
        }
        ringBuffer?.append(audioBuffer, when: when)
        applyOutageClockJump()
        applyWallReanchor()
        resample()
    }

    /// Mirrors the ring buffer's microphone-outage clock jump on the output
    /// timeline. The ring advances its own clock when an interruption ends on a
    /// capture timeline that never reported the elapsed time; without the same
    /// step here every block after the outage would be stamped early by the
    /// outage length (audio running ahead of video). Must run before `resample()`
    /// so the blocks emitted by this append already carry the corrected time.
    @inline(__always)
    private func applyOutageClockJump() {
        guard let ringBuffer, 0 < ringBuffer.lastClockJumpSeconds else {
            return
        }
        audioTime.advanced(seconds: ringBuffer.lastClockJumpSeconds)
        recordClockJump(ringBuffer.lastClockJumpSeconds)
    }

    @inline(__always)
    private func resample() {
        guard let outputBuffer, let inputBuffer, let ringBuffer else {
            return
        }
        var status: AVAudioConverterOutputStatus? = .endOfStream
        repeat {
            var error: NSError?
            status = audioConverter?.convert(to: outputBuffer, error: &error) { inNumberFrames, status in
                if inNumberFrames <= ringBuffer.counts {
                    _ = ringBuffer.render(inNumberFrames, ioData: inputBuffer.mutableAudioBufferList)
                    inputBuffer.frameLength = inNumberFrames
                    status.pointee = .haveData
                    return inputBuffer
                } else {
                    status.pointee = .noDataNow
                    return nil
                }
            }
            switch status {
            case .haveData:
                delegate?.track(self, didOutput: outputBuffer.muted(settings.isMuted), when: audioTime.at)
                audioTime.advanced(1024)
            case .error:
                if let error {
                    delegate?.track(self, errorOccurred: .failedToConvert(error: error))
                }
            default:
                break
            }
        } while(status == .haveData)
    }

    private func setUp(_ inSourceFormat: CMFormatDescription?) {
        guard let inputFormat = AVAudioUtil.makeAudioFormat(inSourceFormat) else {
            delegate?.track(self, errorOccurred: .failedToCreate(from: inputFormat, to: outputFormat))
            return
        }
        inputBuffer = .init(pcmFormat: inputFormat, frameCapacity: 1024 * 4)
        ringBuffer = .init(inputFormat)
        outputBuffer = .init(pcmFormat: outputFormat, frameCapacity: kIOAudioMixerTrack_frameCapacity)
        if logger.isEnabledFor(level: .info) {
            logger.info("inputFormat:", inputFormat, ", outputFormat:", outputFormat)
        }
        audioTime.reset()
        wallLagFirstSeenMachSeconds = 0
        audioConverter = .init(from: inputFormat, to: outputFormat)
    }
}
