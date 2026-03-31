import Foundation
import ARKit
import CoreImage
import Combine
import UIKit

final class ARSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    let dataWriter = DataWriter()
    let imuRecorder = IMURecorder()
    let frameFilter = FrameFilter()

    @Published var isRecording = false
    @Published var frameCount = 0
    @Published var hasDepth = false
    @Published var trackingState: String = "Not Available"
    @Published var currentSessionID: String?
    @Published var logLines: [String] = []
    @Published var movingTooFast = false

    private var frameIndex = 0
    private var droppedCount = 0
    private var sessionMetadata: RecordingSession?
    private let ciContext = CIContext()
    private var isPreviewRunning = false
    private var arConfig: ARWorldTrackingConfiguration?

    private var _cgOrientation: CGImagePropertyOrientation = .right
    private let orientationLock = NSLock()
    private var cgOrientation: CGImagePropertyOrientation {
        get { orientationLock.lock(); defer { orientationLock.unlock() }; return _cgOrientation }
        set { orientationLock.lock(); defer { orientationLock.unlock() }; _cgOrientation = newValue }
    }
    private var orientationString: String = "portrait"

    private var hideTooFastTask: DispatchWorkItem?

    override init() {
        super.init()
        session.delegate = self
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        updateOrientation()
    }

    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    @objc private func deviceOrientationChanged() { updateOrientation() }

    private func updateOrientation() {
        let o = UIDevice.current.orientation
        switch o {
        case .portrait:            cgOrientation = .right; orientationString = "portrait"
        case .portraitUpsideDown:  cgOrientation = .left;  orientationString = "portraitUpsideDown"
        case .landscapeLeft:       cgOrientation = .down;  orientationString = "landscapeLeft"
        case .landscapeRight:      cgOrientation = .up;    orientationString = "landscapeRight"
        default: break
        }
    }

    func startPreview() {
        guard !isPreviewRunning else { return }
        let config = makeConfig()
        arConfig = config
        session.run(config)
        isPreviewRunning = true
        hasDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private func makeConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.isAutoFocusEnabled = true
        if let bestFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first {
            config.videoFormat = bestFormat
        }
        return config
    }

    func startRecording() {
        if !isPreviewRunning { startPreview() }

        let supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        hasDepth = supportsDepth

        let sessionURL = dataWriter.createSession()
        let sessionID = sessionURL.lastPathComponent
        currentSessionID = sessionID

        let rgbRes: [Int]
        if let fmt = arConfig?.videoFormat {
            rgbRes = [Int(fmt.imageResolution.width), Int(fmt.imageResolution.height)]
        } else {
            rgbRes = [1920, 1440]
        }

        sessionMetadata = RecordingSession.create(
            sessionID: sessionID,
            hasDepth: supportsDepth,
            rgbResolution: rgbRes,
            depthResolution: supportsDepth ? [256, 192] : nil
        )

        frameIndex = 0
        droppedCount = 0
        frameCount = 0
        logLines = []
        frameFilter.reset()
        addLog("Started: \(sessionID)")
        addLog("Filter: \(Int(frameFilter.targetFPS))fps, sharpness≥\(Int(frameFilter.minSharpness))")

        imuRecorder.start()
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
        imuRecorder.stop()

        guard var metadata = sessionMetadata else { return }
        metadata.endTimestamp = ProcessInfo.processInfo.systemUptime
        metadata.frameCount = frameIndex
        dataWriter.finalizeSession(metadata: metadata)

        addLog("Saved \(frameIndex) frames, dropped \(droppedCount)")

        sessionMetadata = nil
        currentSessionID = nil
    }

    private func addLog(_ msg: String) {
        DispatchQueue.main.async {
            self.logLines.append(msg)
            if self.logLines.count > 3 { self.logLines.removeFirst() }
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let state: String
        switch frame.camera.trackingState {
        case .normal: state = "normal"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: state = "limited_motion"
            case .insufficientFeatures: state = "limited_features"
            case .initializing: state = "initializing"
            case .relocalizing: state = "relocalizing"
            @unknown default: state = "limited"
            }
        case .notAvailable: state = "not_available"
        }
        DispatchQueue.main.async { self.trackingState = state }

        guard isRecording else { return }

        // Run frame filter
        let result = frameFilter.evaluate(frame: frame)

        // Show toast on fast movement; ignore re-triggers while timer is running
        if frameFilter.isMovingTooFast && hideTooFastTask == nil {
            DispatchQueue.main.async { self.movingTooFast = true }
            let task = DispatchWorkItem {
                DispatchQueue.main.async { self.movingTooFast = false }
                self.hideTooFastTask = nil
            }
            hideTooFastTask = task
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0, execute: task)
        }

        if !result.shouldKeep {
            droppedCount += 1
            return
        }

        let index = frameIndex
        frameIndex += 1

        // RGB -> JPEG with device orientation correction
        let capturedOrientation = cgOrientation
        let capturedOrientationString = orientationString
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage).oriented(capturedOrientation)
        if let jpegData = ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        ) {
            dataWriter.writeRGBFrame(index: index, jpegData: jpegData)
        }

        // Depth + confidence
        var depthW = 0, depthH = 0
        if let depthMap = frame.sceneDepth?.depthMap {
            dataWriter.writeDepthMap(index: index, depthBuffer: depthMap)
            depthW = CVPixelBufferGetWidth(depthMap)
            depthH = CVPixelBufferGetHeight(depthMap)
            if index == 0 { sessionMetadata?.depthResolution = [depthW, depthH] }
        }
        if let confidenceMap = frame.sceneDepth?.confidenceMap {
            dataWriter.writeConfidenceMap(index: index, confidenceBuffer: confidenceMap)
        }

        // Per-frame metadata
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution

        var meta: [String: Any] = [
            "frame_index": index,
            "timestamp": frame.timestamp,
            "camera_transform": [
                transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
                transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
                transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
                transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w,
            ],
            "camera_intrinsics": [
                intrinsics.columns.0.x, intrinsics.columns.0.y, intrinsics.columns.0.z,
                intrinsics.columns.1.x, intrinsics.columns.1.y, intrinsics.columns.1.z,
                intrinsics.columns.2.x, intrinsics.columns.2.y, intrinsics.columns.2.z,
            ],
            "camera_resolution": [resolution.width, resolution.height],
            "camera_euler_angles": [
                frame.camera.eulerAngles.x,
                frame.camera.eulerAngles.y,
                frame.camera.eulerAngles.z,
            ],
            "tracking_state": state,
            "device_orientation": capturedOrientationString,
            "exposure_duration": frame.camera.exposureDuration,
            "exposure_offset": frame.camera.exposureOffset,
            "has_depth": frame.sceneDepth != nil,
            "frame_sharpness": result.sharpness,
        ]

        if depthW > 0 { meta["depth_resolution"] = [depthW, depthH] }
        if let points = frame.rawFeaturePoints { meta["feature_point_count"] = points.points.count }
        if let light = frame.lightEstimate {
            meta["ambient_intensity"] = light.ambientIntensity
            meta["ambient_color_temperature"] = light.ambientColorTemperature
        }
        if let imu = imuRecorder.currentReading() {
            for (key, value) in imu { meta[key] = value }
        }

        dataWriter.appendFrameMetadata(meta)

        DispatchQueue.main.async { self.frameCount = self.frameIndex }
    }
}
