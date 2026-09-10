import AVFoundation
import CoreFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

// MARK: -
/**
 * The VideoCodec class provides methods for encode or decode for video.
 */
final class VideoCodec {
    static let frameInterval: Double = 0.0

    /// Specifies the settings for a VideoCodec.
    var settings: VideoCodecSettings = .default {
        didSet {
            let invalidateSession = settings.invalidateSession(oldValue)
            if invalidateSession {
                self.isInvalidateSession = invalidateSession
            } else {
                settings.apply(self, rhs: oldValue)
            }
        }
    }
    var needsSync = true
    var passthrough = true
    var outputStream: AsyncStream<CMSampleBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    var frameInterval = VideoCodec.frameInterval
    var expectedFrameRate = MediaMixer.defaultFrameRate
    private var startedAt: CMTime = .zero
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var isInvalidateSession = true
    private var presentationTimeStamp: CMTime = .zero
    /// Next due slot (seconds, PTS domain) of the frame-dropping gate.
    private var nextFrameDue: Double = 0
    /// Whether `nextFrameDue` is armed (false = the next frame anchors it).
    private var hasFrameDue = false
    private(set) var isRunning = false
    private(set) var inputFormat: CMFormatDescription? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            isInvalidateSession = true
            outputFormat = nil
        }
    }
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
            isInvalidateSession = false
        }
    }
    private(set) var outputFormat: CMFormatDescription?

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        do {
            inputFormat = sampleBuffer.formatDescription
            if isInvalidateSession {
                if sampleBuffer.formatDescription?.isCompressed == true {
                    session = try VTSessionMode.decompression.makeSession(self)
                } else {
                    session = try VTSessionMode.compression.makeSession(self)
                }
            }
            guard let session, let continuation else {
                return
            }
            if sampleBuffer.formatDescription?.isCompressed == true {
                try session.convert(sampleBuffer, continuation: continuation)
            } else {
                if useFrame(sampleBuffer.presentationTimeStamp) {
                    try session.convert(sampleBuffer, continuation: continuation)
                }
            }
        } catch {
            logger.error(error)
        }
    }

    func makeImageBufferAttributes(_ mode: VTSessionMode) -> [NSString: AnyObject]? {
        switch mode {
        case .compression:
            var attributes: [NSString: AnyObject] = [:]
            if let inputFormat {
                // Specify the pixel format of the uncompressed video.
                attributes[kCVPixelBufferPixelFormatTypeKey] = inputFormat.mediaType.rawValue as CFNumber
            }
            return attributes.isEmpty ? nil : attributes
        case .decompression:
            return [
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
            ]
        }
    }

    /// Frame-dropping gate for the target cadence (`frameInterval`, seconds).
    ///
    /// v2026-09 fork fix (upstream bug): the previous minimum-gap comparison
    /// never stored the accepted frame's PTS (`presentationTimeStamp` stayed
    /// .zero), so the gate compared against seconds-since-start and passed
    /// EVERY frame — the throttle was a no-op and the stream always ran at
    /// capture fps. The gate now writes back the accepted PTS and paces with
    /// a Bresenham accumulator: the candidate frame is encoded when it
    /// reaches the next due slot and the remainder is carried, so ANY
    /// capture/target ratio holds its exact average (a minimum-gap gate only
    /// yields capture-rate divisors — a 20 fps target off a 30 fps capture
    /// realized 15). Long gaps (background/resume) re-anchor so a stale due
    /// slot never emits a burst.
    private func useFrame(_ presentationTimeStamp: CMTime) -> Bool {
        guard startedAt <= presentationTimeStamp else {
            return false
        }
        guard self.presentationTimeStamp < presentationTimeStamp else {
            return false
        }
        guard Self.frameInterval < frameInterval else {
            self.presentationTimeStamp = presentationTimeStamp
            return true
        }
        let pts = presentationTimeStamp.seconds
        if hasFrameDue, pts < nextFrameDue {
            return false
        }
        if hasFrameDue, pts - nextFrameDue <= frameInterval * 2 {
            nextFrameDue += frameInterval
        } else {
            nextFrameDue = pts + frameInterval
        }
        hasFrameDue = true
        self.presentationTimeStamp = presentationTimeStamp
        return true
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @objc
    private func applicationWillEnterForeground(_ notification: Notification) {
        isInvalidateSession = true
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            isInvalidateSession = true
        default:
            break
        }
    }
    #endif
}

extension VideoCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
        startedAt = passthrough ? .zero : CMClockGetTime(CMClockGetHostTimeClock())
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        session = nil
        isInvalidateSession = true
        needsSync = true
        inputFormat = nil
        outputFormat = nil
        presentationTimeStamp = .zero
        nextFrameDue = 0
        hasFrameDue = false
        continuation?.finish()
        startedAt = .zero
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}
