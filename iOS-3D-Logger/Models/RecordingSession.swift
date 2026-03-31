import Foundation

struct RecordingSession: Codable {
    var sessionID: String
    var deviceModel: String
    var osVersion: String
    var startTimestamp: Double
    var endTimestamp: Double
    var frameCount: Int
    var hasDepth: Bool
    var rgbResolution: [Int]
    var depthResolution: [Int]?

    static func create(sessionID: String, hasDepth: Bool, rgbResolution: [Int], depthResolution: [Int]?) -> RecordingSession {
        var sysInfo = utsname()
        uname(&sysInfo)
        let model = withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }

        return RecordingSession(
            sessionID: sessionID,
            deviceModel: model,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            startTimestamp: ProcessInfo.processInfo.systemUptime,
            endTimestamp: 0,
            frameCount: 0,
            hasDepth: hasDepth,
            rgbResolution: rgbResolution,
            depthResolution: depthResolution
        )
    }
}
