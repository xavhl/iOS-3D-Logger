import Foundation
import CoreMotion

final class IMURecorder {
    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private(set) var sampleCount = 0
    private weak var dataWriter: DataWriter?

    init() {
        queue.name = "com.ios3dlogger.imu"
        queue.maxConcurrentOperationCount = 1
    }

    func start(dataWriter: DataWriter) {
        self.dataWriter = dataWriter
        sampleCount = 0

        guard motionManager.isDeviceMotionAvailable else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 100.0 // 100 Hz
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            self.sampleCount += 1

            let line = String(
                format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
                m.timestamp,
                m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z,
                m.rotationRate.x, m.rotationRate.y, m.rotationRate.z,
                m.gravity.x, m.gravity.y, m.gravity.z,
                m.attitude.roll, m.attitude.pitch, m.attitude.yaw
            )
            self.dataWriter?.appendIMUSample(line)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
