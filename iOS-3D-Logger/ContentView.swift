import SwiftUI

struct ContentView: View {
    @StateObject private var manager = ARSessionManager()

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Text("3D Logger")
                .font(.largeTitle.bold())

            VStack(spacing: 12) {
                StatusRow(label: "Tracking", value: manager.trackingState)
                StatusRow(label: "Frames", value: "\(manager.frameCount)")
                StatusRow(label: "IMU Samples", value: "\(manager.imuRecorder.sampleCount)")
                StatusRow(label: "LiDAR Depth", value: manager.hasDepth ? "Available" : "Not Available")
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            Spacer()

            Button(action: {
                if manager.isRecording {
                    manager.stopRecording()
                } else {
                    manager.startRecording()
                }
            }) {
                Circle()
                    .fill(manager.isRecording ? Color.red : Color.green)
                    .frame(width: 80, height: 80)
                    .overlay(
                        Image(systemName: manager.isRecording ? "stop.fill" : "record.circle")
                            .font(.title)
                            .foregroundColor(.white)
                    )
            }

            Text(manager.isRecording ? "Tap to stop" : "Tap to record")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }
}

struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}
