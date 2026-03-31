import Foundation
import ARKit
import CoreImage
import Combine

final class ARSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    let dataWriter = DataWriter()
    let imuRecorder = IMURecorder()

    @Published var isRecording = false
    @Published var frameCount = 0
    @Published var hasDepth = false
    @Published var trackingState: String = "Not Available"
    @Published var currentSessionID: String?
    @Published var logLines: [String] = []

    private var frameIndex = 0
    private var sessionMetadata: RecordingSession?
    private let ciContext = CIContext()
    private var isPreviewRunning = false
    private var arConfig: ARWorldTrackingConfiguration?

    override init() {
        super.init()
        session.delegate = self
    }

    func startPreview() {
        guard !isPreviewRunning else { return }
        let config = makeConfig()
        arConfig = config
        session.run(config)
        isPreviewRunning = true
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
        if !isPreviewRunning {
            startPreview()
        }

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
        frameCount = 0
        logLines = []
        addLog("Started: \(sessionID)")

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

        addLog("Saved \(frameIndex) frames")

        sessionMetadata = nil
        currentSessionID = nil
    }

    private func addLog(_ msg: String) {
        DispatchQueue.main.async {
            self.logLines.append(msg)
            if self.logLines.count > 3 {
                self.logLines.removeFirst()
            }
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

        let index = frameIndex
        frameIndex += 1

        // RGB frame -> JPEG
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let jpegData = ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        )
        if let jpegData {
            dataWriter.writeRGBFrame(index: index, jpegData: jpegData)
        }

        // Depth + confidence (per-frame, synced to this ARFrame)
        var depthW = 0, depthH = 0
        if let depthMap = frame.sceneDepth?.depthMap {
            dataWriter.writeDepthMap(index: index, depthBuffer: depthMap)
            depthW = CVPixelBufferGetWidth(depthMap)
            depthH = CVPixelBufferGetHeight(depthMap)
            if index == 0 {
                sessionMetadata?.depthResolution = [depthW, depthH]
            }
        }
        if let confidenceMap = frame.sceneDepth?.confidenceMap {
            dataWriter.writeConfidenceMap(index: index, confidenceBuffer: confidenceMap)
        }

        // Build unified per-frame metadata (everything synced to frame.timestamp)
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
            "exposure_duration": frame.camera.exposureDuration,
            "exposure_offset": frame.camera.exposureOffset,
            "has_depth": frame.sceneDepth != nil,
        ]

        if depthW > 0 {
            meta["depth_resolution"] = [depthW, depthH]
        }

        if let points = frame.rawFeaturePoints {
            meta["feature_point_count"] = points.points.count
        }

        if let light = frame.lightEstimate {
            meta["ambient_intensity"] = light.ambientIntensity
            meta["ambient_color_temperature"] = light.ambientColorTemperature
        }

        // IMU data synced per-frame
        if let imu = imuRecorder.currentReading() {
            for (key, value) in imu {
                meta[key] = value
            }
        }

        dataWriter.appendFrameMetadata(meta)

        // Update UI
        DispatchQueue.main.async {
            self.frameCount = self.frameIndex
        }

        if index % 30 == 0 && index > 0 {
            addLog("f:\(index) trk:\(state)")
        }
    }
}
