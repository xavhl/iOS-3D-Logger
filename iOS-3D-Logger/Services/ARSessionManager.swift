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

    private var frameIndex = 0
    private var sessionMetadata: RecordingSession?
    private let ciContext = CIContext()

    override init() {
        super.init()
        session.delegate = self
    }

    func startRecording() {
        let config = ARWorldTrackingConfiguration()

        // Enable LiDAR depth if available
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            hasDepth = true
        } else {
            hasDepth = false
        }

        config.isAutoFocusEnabled = true

        // Prefer highest resolution video format
        if let bestFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first {
            config.videoFormat = bestFormat
        }

        session.run(config)

        let sessionURL = dataWriter.createSession()
        let sessionID = sessionURL.lastPathComponent

        let rgbRes: [Int]
        if let fmt = config.videoFormat as ARConfiguration.VideoFormat? {
            rgbRes = [Int(fmt.imageResolution.width), Int(fmt.imageResolution.height)]
        } else {
            rgbRes = [1920, 1440]
        }

        var depthRes: [Int]? = nil
        if hasDepth {
            depthRes = [256, 192] // Standard LiDAR resolution on iPhone/iPad
        }

        sessionMetadata = RecordingSession.create(
            sessionID: sessionID,
            hasDepth: hasDepth,
            rgbResolution: rgbRes,
            depthResolution: depthRes
        )

        frameIndex = 0
        frameCount = 0

        imuRecorder.start(dataWriter: dataWriter)
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
        imuRecorder.stop()
        session.pause()

        guard var metadata = sessionMetadata else { return }
        metadata.endTimestamp = ProcessInfo.processInfo.systemUptime
        metadata.frameCount = frameIndex
        metadata.imuSampleCount = imuRecorder.sampleCount
        dataWriter.finalizeSession(metadata: metadata)
        sessionMetadata = nil
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }

        let index = frameIndex
        frameIndex += 1

        DispatchQueue.main.async {
            self.frameCount = self.frameIndex
        }

        // Update tracking state
        let state: String
        switch frame.camera.trackingState {
        case .normal: state = "normal"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: state = "limited_excessive_motion"
            case .insufficientFeatures: state = "limited_insufficient_features"
            case .initializing: state = "limited_initializing"
            case .relocalizing: state = "limited_relocalizing"
            @unknown default: state = "limited_unknown"
            }
        case .notAvailable: state = "not_available"
        }
        DispatchQueue.main.async { self.trackingState = state }

        // RGB frame -> JPEG
        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        if let jpegData = ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        ) {
            dataWriter.writeRGBFrame(index: index, jpegData: jpegData)
        }

        // Depth map
        if let depthMap = frame.sceneDepth?.depthMap {
            dataWriter.writeDepthMap(index: index, depthBuffer: depthMap)

            // Update actual depth resolution in metadata on first frame
            if index == 0 {
                let w = CVPixelBufferGetWidth(depthMap)
                let h = CVPixelBufferGetHeight(depthMap)
                sessionMetadata?.depthResolution = [w, h]
            }
        }

        // Confidence map
        if let confidenceMap = frame.sceneDepth?.confidenceMap {
            dataWriter.writeConfidenceMap(index: index, confidenceBuffer: confidenceMap)
        }

        // Frame metadata
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
        ]

        // Feature points
        if let points = frame.rawFeaturePoints {
            meta["feature_point_count"] = points.points.count
        }

        // Light estimate
        if let light = frame.lightEstimate {
            meta["ambient_intensity"] = light.ambientIntensity
            meta["ambient_color_temperature"] = light.ambientColorTemperature
        }

        dataWriter.appendFrameMetadata(meta)
    }
}
