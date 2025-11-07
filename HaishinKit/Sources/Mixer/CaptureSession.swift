import AVFoundation

protocol CaptureSessionConvertible: Runner {
    #if !os(visionOS)
    @available(tvOS 17.0, *)
    var sessionPreset: AVCaptureSession.Preset { get set }
    #endif

    var isInturreped: AsyncStream<Bool> { get }
    var runtimeError: AsyncStream<AVError> { get }
    var isMultiCamSessionEnabled: Bool { get set }
    @available(tvOS 17.0, *)
    var isMultitaskingCameraAccessEnabled: Bool { get }

    @available(tvOS 17.0, *)
    func attachCapture(_ capture: (any DeviceUnit)?)
    @available(tvOS 17.0, *)
    func detachCapture(_ capture: (any DeviceUnit)?)
    @available(tvOS 17.0, *)
    func configuration(_ lambda: (_ session: AVCaptureSession) throws -> Void ) rethrows
    @available(tvOS 17.0, *)
    func startRunningIfNeeded()
}

final class CaptureSession: CaptureSessionConvertible {
    #if os(iOS) || os(tvOS)
    static var isMultiCamSupported: Bool {
        if #available(tvOS 17.0, *) {
            return AVCaptureMultiCamSession.isMultiCamSupported
        } else {
            return false
        }
    }
    #elseif os(macOS)
    static let isMultiCamSupported = true
    #elseif os(visionOS)
    static let isMultiCamSupported = false
    #endif

    #if os(iOS) || os(tvOS)
    var isMultiCamSessionEnabled = false {
        didSet {
            if !Self.isMultiCamSupported {
                isMultiCamSessionEnabled = false
                logger.info("This device can't support the AVCaptureMultiCamSession.")
            }
        }
    }
    @available(tvOS 17.0, *)
    var isMultitaskingCameraAccessEnabled: Bool {
        return session.isMultitaskingCameraAccessEnabled
    }

    #elseif os(macOS)
    var isMultiCamSessionEnabled = true
    let isMultitaskingCameraAccessEnabled = true
    #elseif os(visionOS)
    var isMultiCamSessionEnabled = false
    let isMultitaskingCameraAccessEnabled = false
    #endif

    private(set) var isRunning = false

    @AsyncStreamedFlow
    var isInturreped: AsyncStream<Bool>

    @AsyncStreamedFlow
    var runtimeError: AsyncStream<AVError>

    #if os(tvOS)
    private var _session: Any?
    /// The capture session instance.
    @available(tvOS 17.0, *)
    var session: AVCaptureSession {
        if _session == nil {
            _session = makeSession()
        }
        return _session as! AVCaptureSession
    }

    private var _sessionPreset: Any?
    @available(tvOS 17.0, *)
    var sessionPreset: AVCaptureSession.Preset {
        get {
            if _sessionPreset == nil {
                _sessionPreset = AVCaptureSession.Preset.default
            }
            return _sessionPreset as! AVCaptureSession.Preset
        }
        set {
            guard sessionPreset != newValue, session.canSetSessionPreset(newValue) else {
                return
            }
            session.beginConfiguration()
            session.sessionPreset = newValue
            session.commitConfiguration()
        }
    }
    #elseif os(visionOS)
    /// The capture session instance.
    private(set) lazy var session = AVCaptureSession()
    #else
    var sessionPreset: AVCaptureSession.Preset = .default {
        didSet {
            guard sessionPreset != oldValue, session.canSetSessionPreset(sessionPreset) else {
                return
            }
            session.beginConfiguration()
            session.sessionPreset = sessionPreset
            session.commitConfiguration()
        }
    }

    /// The capture session instance.
    private(set) lazy var session: AVCaptureSession = makeSession()
    #endif

    @available(tvOS 17.0, *)
    private var isMultiCamSession: Bool {
        #if os(iOS) || os(tvOS)
        return session is AVCaptureMultiCamSession
        #else
        return true
        #endif
    }

    deinit {
        guard #available(tvOS 17.0, *) else {
            return
        }
        if session.isRunning {
            session.stopRunning()
        }
    }

    @available(tvOS 17.0, *)
    func configuration(_ lambda: (_ session: AVCaptureSession) throws -> Void ) rethrows {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        try lambda(session)
    }

    @available(tvOS 17.0, *)
    func attachCapture(_ capture: (any DeviceUnit)?) {
        guard let capture else {
            return
        }
        #if !os(visionOS)
        if let connection = capture.connection {
            if let input = capture.input, session.canAddInput(input) {
                session.addInputWithNoConnections(input)
            }
            if let output = capture.output, session.canAddOutput(output) {
                session.addOutputWithNoConnections(output)
            }
            if session.canAddConnection(connection) {
                session.addConnection(connection)
            }
            return
        }
        #endif
        if let input = capture.input, session.canAddInput(input) {
            session.addInput(input)
        }
        if let output = capture.output, session.canAddOutput(output) {
            session.addOutput(output)
        }
    }

    @available(tvOS 17.0, *)
    func detachCapture(_ capture: (any DeviceUnit)?) {
        guard let capture else {
            return
        }
        #if !os(visionOS)
        if let connection = capture.connection {
            if capture.output?.connections.contains(connection) == true {
                session.removeConnection(connection)
            }
        }
        #endif
        if let input = capture.input, session.inputs.contains(input) {
            session.removeInput(input)
        }
        if let output = capture.output, session.outputs.contains(output) {
            session.removeOutput(output)
        }
    }

    @available(tvOS 17.0, *)
    func startRunningIfNeeded() {
        guard isRunning && !session.isRunning else {
            return
        }
        session.startRunning()
        isRunning = session.isRunning
    }

    #if os(iOS) || os(tvOS)
    @available(tvOS 17.0, *)
    private func makeSession() -> AVCaptureSession {
        let session: AVCaptureSession
        if isMultiCamSessionEnabled {
            session = AVCaptureMultiCamSession()
        } else {
            session = AVCaptureSession()
        }
        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
        }
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        return session
    }
    #elseif os(macOS)
    private func makeSession() -> AVCaptureSession {
        let session = AVCaptureSession()
        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
        }
        return session
    }
    #endif

    @available(tvOS 17.0, *)
    private func addSessionObservers(_ session: AVCaptureSession) {
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)), name: .AVCaptureSessionRuntimeError, object: session)
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)), name: .AVCaptureSessionInterruptionEnded, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted(_:)), name: .AVCaptureSessionWasInterrupted, object: session)
        #endif
    }

    @available(tvOS 17.0, *)
    private func removeSessionObservers(_ session: AVCaptureSession) {
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: session)
        #endif
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
        _runtimeError.finish()
    }

    @available(tvOS 17.0, *)
    @objc
    private func sessionRuntimeError(_ notification: NSNotification) {
        guard
            let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        _runtimeError.yield(AVError(_nsError: errorValue))
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @available(tvOS 17.0, *)
    @objc
    private func sessionWasInterrupted(_ notification: Notification) {
        _isInturreped.yield(true)
    }

    @available(tvOS 17.0, *)
    @objc
    private func sessionInterruptionEnded(_ notification: Notification) {
        _isInturreped.yield(false)
    }
    #endif
}

extension CaptureSession: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        if #available(tvOS 17.0, *) {
            addSessionObservers(session)
            session.startRunning()
            isRunning = session.isRunning
        } else {
            isRunning = true
        }
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        if #available(tvOS 17.0, *) {
            removeSessionObservers(session)
            session.stopRunning()
            isRunning = session.isRunning
        } else {
            isRunning = false
        }
    }
}

final class NullCaptureSession: CaptureSessionConvertible {
    private(set) var isRunning: Bool = false

    #if !os(visionOS)
    @available(tvOS 17.0, *)
    var sessionPreset: AVCaptureSession.Preset {
        get {
            return .default
        }
        set {
        }
    }
    #endif

    @AsyncStreamed(false) var isInturreped: AsyncStream<Bool>
    @AsyncStreamedFlow var runtimeError: AsyncStream<AVError>
    var isMultiCamSessionEnabled: Bool = false
    var isMultitaskingCameraAccessEnabled: Bool = false

    @available(tvOS 17.0, *)
    func attachCapture(_ capture: (any DeviceUnit)?) {
    }

    @available(tvOS 17.0, *)
    func detachCapture(_ capture: (any DeviceUnit)?) {
    }

    @available(tvOS 17.0, *)
    func configuration(_ lambda: (AVCaptureSession) throws -> Void) rethrows {
    }

    func startRunningIfNeeded() {
    }

    func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        _runtimeError.finish()
        isRunning = false
    }
}
