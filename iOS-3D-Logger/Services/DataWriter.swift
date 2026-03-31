import Foundation
import CoreVideo

final class DataWriter {
    private let queue = DispatchQueue(label: "com.ios3dlogger.datawriter", qos: .userInitiated)
    private var sessionURL: URL?
    private var framesFileHandle: FileHandle?

    func createSession() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "session_\(formatter.string(from: Date()))"
        let url = docs.appendingPathComponent(name)

        let fm = FileManager.default
        try? fm.createDirectory(at: url.appendingPathComponent("rgb"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: url.appendingPathComponent("depth"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: url.appendingPathComponent("confidence"), withIntermediateDirectories: true)

        let framesPath = url.appendingPathComponent("frames.jsonl")
        fm.createFile(atPath: framesPath.path, contents: nil)
        framesFileHandle = FileHandle(forWritingAtPath: framesPath.path)

        sessionURL = url
        return url
    }

    func writeRGBFrame(index: Int, jpegData: Data) {
        guard let sessionURL else { return }
        queue.async {
            let path = sessionURL.appendingPathComponent("rgb/\(String(format: "%06d", index)).jpg")
            try? jpegData.write(to: path)
        }
    }

    func writeDepthMap(index: Int, depthBuffer: CVPixelBuffer) {
        guard let sessionURL else { return }
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else {
            CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)
            return
        }
        let data = Data(bytes: baseAddress, count: width * height * MemoryLayout<Float32>.size)
        CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)

        queue.async {
            let path = sessionURL.appendingPathComponent("depth/\(String(format: "%06d", index)).bin")
            try? data.write(to: path)
        }
    }

    func writeConfidenceMap(index: Int, confidenceBuffer: CVPixelBuffer) {
        guard let sessionURL else { return }
        CVPixelBufferLockBaseAddress(confidenceBuffer, .readOnly)
        let width = CVPixelBufferGetWidth(confidenceBuffer)
        let height = CVPixelBufferGetHeight(confidenceBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(confidenceBuffer) else {
            CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly)
            return
        }
        let data = Data(bytes: baseAddress, count: width * height * MemoryLayout<UInt8>.size)
        CVPixelBufferUnlockBaseAddress(confidenceBuffer, .readOnly)

        queue.async {
            let path = sessionURL.appendingPathComponent("confidence/\(String(format: "%06d", index)).bin")
            try? data.write(to: path)
        }
    }

    func appendFrameMetadata(_ json: [String: Any]) {
        queue.async { [weak self] in
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            self?.framesFileHandle?.write(line.data(using: .utf8)!)
        }
    }

    func finalizeSession(metadata: RecordingSession) {
        queue.async { [weak self] in
            guard let sessionURL = self?.sessionURL else { return }
            self?.framesFileHandle?.closeFile()
            self?.framesFileHandle = nil

            let path = sessionURL.appendingPathComponent("metadata.json")
            if let data = try? JSONEncoder().encode(metadata) {
                try? data.write(to: path)
            }
            self?.sessionURL = nil
        }
    }
}
