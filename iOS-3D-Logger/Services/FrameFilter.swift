import Foundation
import ARKit
import Accelerate

/// Decides whether an ARFrame should be recorded.
/// Applies four sequential gates: frame rate, tracking, motion, and sharpness.
final class FrameFilter {

    // MARK: - Configuration

    /// Target recording frame rate. Frames are dropped to match this rate.
    var targetFPS: Double = 5.0

    /// Maximum allowed camera translation (meters) since the last kept frame.
    var maxTranslation: Float = 0.05

    /// Maximum allowed camera rotation (radians) since the last kept frame.
    var maxRotation: Float = 0.1

    /// Minimum Laplacian variance for a frame to be considered sharp.
    /// Lower = more permissive. Tune based on your content.
    var minSharpness: Float = 80.0

    // MARK: - State

    private var lastKeptTimestamp: Double = 0
    private var lastKeptTransform: simd_float4x4? = nil
    /// Updated every ARFrame — used for instantaneous speed warning only.
    private var lastFrameTransform: simd_float4x4? = nil

    /// Reflects instantaneous motion speed — updated every frame regardless of gates.
    private(set) var isMovingTooFast: Bool = false

    enum DropReason {
        case frameRate
        case trackingLost
        case tooFast
        case blurry
    }

    struct Result {
        let shouldKeep: Bool
        let dropReason: DropReason?
        let sharpness: Float
    }

    func evaluate(frame: ARFrame) -> Result {
        let ts = frame.timestamp
        let transform = frame.camera.transform

        // Update instantaneous speed warning using every frame delta (~30fps)
        let (instantTrans, instantRot) = motionDelta(from: lastFrameTransform, to: transform)
        // Scale thresholds to per-frame interval (~1/30s) from per-kept-frame interval (1/targetFPS)
        let frameScale = Float(1.0 / (30.0 / targetFPS))
        isMovingTooFast = lastFrameTransform != nil &&
            (instantTrans > maxTranslation * frameScale || instantRot > maxRotation * frameScale)
        lastFrameTransform = transform

        // --- 1. Frame rate gate ---
        let minInterval = 1.0 / targetFPS
        guard ts - lastKeptTimestamp >= minInterval else {
            return Result(shouldKeep: false, dropReason: .frameRate, sharpness: 0)
        }

        // --- 2. Tracking state gate ---
        if case .normal = frame.camera.trackingState { } else {
            return Result(shouldKeep: false, dropReason: .trackingLost, sharpness: 0)
        }

        // --- 3. Motion gate (vs last kept frame — ensures enough baseline for reconstruction) ---
        let (transDelta, rotDelta) = motionDelta(from: lastKeptTransform, to: transform)
        if lastKeptTransform != nil, transDelta > maxTranslation || rotDelta > maxRotation {
            return Result(shouldKeep: false, dropReason: .tooFast, sharpness: 0)
        }

        // --- 4. Sharpness gate ---
        let sharpness = laplacianVariance(frame.capturedImage)
        guard sharpness >= minSharpness else {
            lastKeptTimestamp = ts
            lastKeptTransform = transform
            return Result(shouldKeep: false, dropReason: .blurry, sharpness: sharpness)
        }

        // All gates passed
        lastKeptTimestamp = ts
        lastKeptTransform = transform
        return Result(shouldKeep: true, dropReason: nil, sharpness: sharpness)
    }

    func reset() {
        lastKeptTimestamp = 0
        lastKeptTransform = nil
        lastFrameTransform = nil
        isMovingTooFast = false
    }

    // MARK: - Helpers

    private func motionDelta(from prev: simd_float4x4?, to current: simd_float4x4) -> (Float, Float) {
        guard let prev else { return (0, 0) }

        // Translation delta
        let dp = current.columns.3 - prev.columns.3
        let transDelta = sqrt(dp.x * dp.x + dp.y * dp.y + dp.z * dp.z)

        // Rotation delta via relative rotation matrix -> angle
        let relRot = simd_mul(simd_inverse(prev), current)
        // Angle from rotation matrix: theta = arccos((trace - 1) / 2)
        let trace = relRot.columns.0.x + relRot.columns.1.y + relRot.columns.2.z
        let cosAngle = max(-1, min(1, (trace - 1) / 2))
        let rotDelta = acos(cosAngle)

        return (transDelta, rotDelta)
    }

    /// Laplacian variance using vDSP — fast, runs on any iOS version.
    /// Operates on a downsampled luma plane to keep cost low.
    private func laplacianVariance(_ pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Use the luma (Y) plane directly from YCbCr buffer
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let fullWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let fullHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // Downsample 4x for speed (process every 4th pixel in each dimension)
        let step = 4
        let width = fullWidth / step
        let height = fullHeight / step
        let count = width * height

        guard count > 0 else { return 0 }

        var luma = [Float](repeating: 0, count: count)
        let src = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0 ..< height {
            for col in 0 ..< width {
                let srcRow = row * step
                let srcCol = col * step
                let byte = src[srcRow * bytesPerRow + srcCol]
                luma[row * width + col] = Float(byte)
            }
        }

        // Discrete Laplacian kernel: [0,1,0, 1,-4,1, 0,1,0]
        // Approximate via vDSP: variance of (luma - mean) correlates with sharpness.
        // For speed use the full Laplacian via a simple finite-difference pass.
        var laplacian = [Float](repeating: 0, count: count)
        for row in 1 ..< height - 1 {
            for col in 1 ..< width - 1 {
                let idx = row * width + col
                laplacian[idx] = luma[idx - width] + luma[idx + width]
                              + luma[idx - 1]     + luma[idx + 1]
                              - 4 * luma[idx]
            }
        }

        var mean: Float = 0
        var variance: Float = 0
        vDSP_meanv(laplacian, 1, &mean, vDSP_Length(count))
        var shifted = laplacian
        var negMean = -mean
        vDSP_vsadd(laplacian, 1, &negMean, &shifted, 1, vDSP_Length(count))
        vDSP_measqv(shifted, 1, &variance, vDSP_Length(count))

        return variance
    }
}
