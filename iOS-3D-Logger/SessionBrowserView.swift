import SwiftUI

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct SessionBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionInfo] = []
    @State private var sharePayload: SharePayload? = nil
    @State private var isZipping = false
    @State private var zipError: String? = nil

    var body: some View {
        NavigationView {
            Group {
                if sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No recordings yet")
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(sessions) { session in
                            SessionRow(session: session, onExport: { exportSession(session) })
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: loadSessions)
            .refreshable { loadSessions() }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.items)
            }
            .alert("Export Failed", isPresented: Binding(
                get: { zipError != nil },
                set: { if !$0 { zipError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(zipError ?? "")
            }
            .overlay {
                if isZipping {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.4)
                            Text("Preparing export…")
                                .foregroundColor(.white)
                                .font(.subheadline)
                        }
                        .padding(32)
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                    }
                }
            }
        }
    }

    private func loadSessions() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            sessions = []
            return
        }

        sessions = contents
            .filter { $0.lastPathComponent.hasPrefix("session_") }
            .compactMap { url -> SessionInfo? in
                let metaURL = url.appendingPathComponent("metadata.json")
                let name = url.lastPathComponent

                var frameCount = 0
                var hasDepth = false

                if let data = try? Data(contentsOf: metaURL),
                   let meta = try? JSONDecoder().decode(RecordingSession.self, from: data) {
                    frameCount = meta.frameCount
                    hasDepth = meta.hasDepth
                }

                let rgbDir = url.appendingPathComponent("rgb")
                let rgbCount = (try? fm.contentsOfDirectory(atPath: rgbDir.path))?.count ?? 0
                if frameCount == 0 { frameCount = rgbCount }

                let size = folderSize(url: url)

                return SessionInfo(
                    id: name,
                    url: url,
                    frameCount: frameCount,
                    hasDepth: hasDepth,
                    sizeBytes: size
                )
            }
            .sorted { $0.id > $1.id }
    }

    private func exportSession(_ session: SessionInfo) {
        isZipping = true
        let sessionURL = session.url
        let zipName = session.id + ".zip"
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(zipName)

        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.removeItem(at: zipURL)

            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            var zipError: String? = nil

            coordinator.coordinate(readingItemAt: sessionURL, options: .forUploading, error: &coordError) { tmpURL in
                do {
                    try FileManager.default.copyItem(at: tmpURL, to: zipURL)
                } catch {
                    zipError = error.localizedDescription
                }
            }

            if coordError != nil {
                zipError = coordError?.localizedDescription
            }

            DispatchQueue.main.async {
                isZipping = false
                if let err = zipError {
                    self.zipError = err
                } else {
                    sharePayload = SharePayload(items: [zipURL])
                }
            }
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            try? FileManager.default.removeItem(at: session.url)
        }
        sessions.remove(atOffsets: offsets)
    }

    private func folderSize(url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Session Info

struct SessionInfo: Identifiable {
    let id: String
    let url: URL
    let frameCount: Int
    let hasDepth: Bool
    let sizeBytes: Int64

    var sizeFormatted: String {
        let mb = Double(sizeBytes) / 1_048_576
        if mb > 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: SessionInfo
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.id.replacingOccurrences(of: "session_", with: ""))
                .font(.headline.monospacedDigit())

            HStack(spacing: 12) {
                Label("\(session.frameCount) frames", systemImage: "photo")
                if session.hasDepth {
                    Label("Depth", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            HStack {
                Text(session.sizeFormatted)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
