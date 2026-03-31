import Foundation
import CoreMotion

final class IMURecorder {
    private let motionManager = CMMotionManager()

    var isAvailable: Bool { motionManager.isDeviceMotionAvailable }

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    /// Returns the latest IMU reading as a dictionary, synchronized to the caller's frame.
    func currentReading() -> [String: Any]? {
        guard let m = motionManager.deviceMotion else { return nil }
        return [
            "imu_timestamp": m.timestamp,
            "user_acceleration": [m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z],
            "rotation_rate": [m.rotationRate.x, m.rotationRate.y, m.rotationRate.z],
            "gravity": [m.gravity.x, m.gravity.y, m.gravity.z],
            "attitude_euler": [m.attitude.roll, m.attitude.pitch, m.attitude.yaw],
            "attitude_quaternion": [m.attitude.quaternion.x, m.attitude.quaternion.y, m.attitude.quaternion.z, m.attitude.quaternion.w],
            "magnetic_field": [m.magneticField.field.x, m.magneticField.field.y, m.magneticField.field.z],
        ]
    }
}
