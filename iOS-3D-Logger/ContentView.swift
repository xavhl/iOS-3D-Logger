import SwiftUI
import RealityKit
import ARKit

// MARK: - AR Camera Preview

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession
    let showDepth: Bool

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session = session
        arView.renderOptions = [
            .disableAREnvironmentLighting,
            .disableMotionBlur,
            .disableDepthOfField,
            .disableFaceOcclusions,
            .disableGroundingShadows,
            .disablePersonOcclusion,
        ]
        arView.cameraMode = .ar
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        if showDepth {
            uiView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            uiView.debugOptions.remove(.showSceneUnderstanding)
        }
    }
}

// MARK: - Depth Overlay (renders depth map as colored image)

struct DepthOverlayView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> DepthUIView {
        let view = DepthUIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ uiView: DepthUIView, context: Context) {
        if let frame = session.currentFrame,
           let depthMap = frame.sceneDepth?.depthMap {
            uiView.updateDepth(depthMap)
        }
    }
}

class DepthUIView: UIView {
    private let imageView = UIImageView()
    private let ciContext = CIContext()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    func updateDepth(_ depthBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: depthBuffer)
        // Normalize and colorize: false color maps depth to visible spectrum
        let filtered = ciImage.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 0, green: 0, blue: 1, alpha: 1),  // near = blue
            "inputColor1": CIColor(red: 1, green: 0, blue: 0, alpha: 1),  // far = red
        ])
        if let cgImage = ciContext.createCGImage(filtered, from: filtered.extent) {
            DispatchQueue.main.async {
                self.imageView.image = UIImage(cgImage: cgImage)
            }
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var manager = ARSessionManager()
    @State private var showSessions = false
    @State private var showDepthView = false
    @State private var showNoDepthAlert = false

    var body: some View {
        ZStack {
            // Full-screen camera
            ARViewContainer(session: manager.session, showDepth: false)
                .ignoresSafeArea()

            // Depth overlay when toggled
            if showDepthView && manager.hasDepth {
                DepthStreamView(session: manager.session)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                Spacer()

                // Bottom bar: Sessions (left) | Record (center) | Depth (right)
                HStack(alignment: .center) {
                    // Sessions button (bottom-left)
                    Button(action: { showSessions = true }) {
                        VStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white)
                            Text("Sessions")
                                .font(.system(size: 9))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 70)

                    Spacer()

                    // Record/Stop button (center)
                    Button(action: {
                        if manager.isRecording {
                            manager.stopRecording()
                        } else {
                            manager.startRecording()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 70, height: 70)

                            if manager.isRecording {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.red)
                                    .frame(width: 28, height: 28)
                            } else {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 58, height: 58)
                            }
                        }
                    }

                    Spacer()

                    // Depth camera toggle (bottom-right)
                    Button(action: {
                        if manager.hasDepth {
                            showDepthView.toggle()
                        } else {
                            showNoDepthAlert = true
                        }
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: "camera.filters")
                                .font(.system(size: 22))
                                .foregroundColor(
                                    manager.hasDepth
                                        ? (showDepthView ? .yellow : .white)
                                        : .gray.opacity(0.5)
                                )
                            Text("Depth")
                                .font(.system(size: 9))
                                .foregroundColor(
                                    manager.hasDepth
                                        ? (showDepthView ? .yellow : .white)
                                        : .gray.opacity(0.5)
                                )
                        }
                    }
                    .frame(width: 70)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 34)
            }
        }
        .onAppear {
            manager.startPreview()
        }
        .sheet(isPresented: $showSessions) {
            SessionBrowserView()
        }
        .alert("Depth Camera Unavailable", isPresented: $showNoDepthAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Depth camera requires a device with LiDAR sensor (iPhone 12 Pro or later Pro models).")
        }
        .statusBarHidden()
    }
}

// MARK: - Depth Stream View (continuously updates depth visualization)

struct DepthStreamView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> DepthStreamUIView {
        let view = DepthStreamUIView(session: session)
        return view
    }

    func updateUIView(_ uiView: DepthStreamUIView, context: Context) {}
}

class DepthStreamUIView: UIView {
    private let imageView = UIImageView()
    private let ciContext = CIContext()
    private var displayLink: CADisplayLink?
    private weak var session: ARSession?

    init(session: ARSession) {
        self.session = session
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)

        displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
        displayLink?.add(to: .main, forMode: .common)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    @objc private func updateFrame() {
        guard let frame = session?.currentFrame,
              let depthMap = frame.sceneDepth?.depthMap else { return }

        let ciImage = CIImage(cvPixelBuffer: depthMap)
        let filtered = ciImage.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 0, green: 0, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 0, blue: 0, alpha: 1),
        ])
        if let cgImage = ciContext.createCGImage(filtered, from: filtered.extent) {
            imageView.image = UIImage(cgImage: cgImage)
        }
    }

    override func removeFromSuperview() {
        displayLink?.invalidate()
        displayLink = nil
        super.removeFromSuperview()
    }
}
