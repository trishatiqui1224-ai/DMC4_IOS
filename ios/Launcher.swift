import GameController
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct DMC4Launcher: App {
    var body: some Scene {
        WindowGroup {
            LauncherView()
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.96, green: 0.36, blue: 0.32))
        }
    }
}

private struct LauncherView: View {
    @AppStorage("selectedGame") private var selectedGame = ""
    @AppStorage("resolutionScale") private var resolutionScale = 1
    @AppStorage("frameRate") private var frameRate = 60
    @AppStorage("masterVolume") private var masterVolume = 1.0
    @AppStorage("muteAudio") private var muteAudio = false
    @AppStorage("touchControls") private var touchControls = true
    @AppStorage("controllerVibration") private var controllerVibration = true
    @AppStorage("debugLogging") private var debugLogging = false
    @State private var game: GameFiles?
    @State private var showImporter = false
    @State private var busy = false
    @State private var error: String?
    @State private var imports: [GameFiles] = []
    @State private var connectedControllerCount = 0
    private let documents = URL.documentsDirectory

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Devil May Cry 4")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        HStack {
                            Text("Xbox 360")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if touchControls {
                                Label("Touch Controls On", systemImage: "hand.tap.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                            if connectedControllerCount > 0 {
                                Label("\(connectedControllerCount) Gamepad", systemImage: "gamecontroller.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                Section {
                    if let game {
                        LabeledContent("Source", value: game.isDisc ? "Xbox 360 ISO" : "Extracted folder")
                        LabeledContent("Shader bundles", value: game.shaderBundleCount.formatted())
                        Text(game.url.lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Add your Xbox 360 ISO or extracted game folder.")
                            .foregroundStyle(.secondary)
                    }
                    if imports.count > 1 {
                        Picker("Game files", selection: $selectedGame) {
                            ForEach(imports, id: \.url) { candidate in
                                Text(candidate.url.lastPathComponent).tag(candidate.url.lastPathComponent)
                            }
                        }
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import from Files", systemImage: "folder.badge.plus")
                    }
                    .disabled(busy)
                    Button {
                        Task { await scan() }
                    } label: {
                        Label("Scan app folder", systemImage: "arrow.clockwise")
                    }
                    .disabled(busy)
                    if busy { ProgressView("Checking game files…") }
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                } header: {
                    Text("Game files")
                } footer: {
                    Text("You can also copy an ISO or extracted folder to Devil May Cry 4 under On My iPhone in Files.")
                }
                Section {
                    Button {
                        if let game {
                            launchGame(game)
                        }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .disabled(busy || game == nil || !dmc4_ios_runtime_available())
                    if !dmc4_ios_runtime_available() {
                        Text("This build does not include the recompiled DMC4 runtime (build/recompiled).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if game == nil {
                        Text("Import or scan an Xbox 360 ISO or extracted folder to play.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings & Controls", systemImage: "gearshape")
                    }
                    NavigationLink {
                        LogViewerView()
                    } label: {
                        Label("Diagnostics & Logs", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.folder, UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]) {
                switch $0 {
                case .success(let url): Task { await importGame(url) }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .task {
                updateControllers()
                await scan()
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
                updateControllers()
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
                updateControllers()
            }
            .onChange(of: selectedGame) { selected in
                game = imports.first { $0.url.lastPathComponent == selected }
            }
        }
    }

    private func updateControllers() {
        connectedControllerCount = GCController.controllers().filter { controller in
            // Filter out internal virtual controller if already connected
            return controller.vendorName != "Virtual Controller"
        }.count
    }

    @MainActor
    private func importGame(_ url: URL) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let directory = documents
            let imported = try await Task.detached(priority: .userInitiated) {
                try GameFiles.importToDocuments(url, documents: directory)
            }.value
            await scanFiles(preferred: imported.url.lastPathComponent)
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func scan() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        await scanFiles(preferred: selectedGame)
    }

    @MainActor
    private func scanFiles(preferred: String) async {
        let directory = documents
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let keys: Set<URLResourceKey> = [.isDirectoryKey]
                let candidates = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
                var games: [GameFiles] = []
                var firstError: String?
                for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let isISO = candidate.pathExtension.lowercased() == "iso"
                    let isDirectory = (try? candidate.resourceValues(forKeys: keys).isDirectory) == true
                    let hasExecutable = isDirectory && FileManager.default.fileExists(
                        atPath: candidate.appendingPathComponent("default.xex").path)
                    guard isISO || hasExecutable || candidate.lastPathComponent == "game" else { continue }
                    do { games.append(try GameFiles(candidate)) }
                    catch { firstError = firstError ?? error.localizedDescription }
                }
                return (games, firstError)
            }.value
            imports = result.0
            game = imports.first { $0.url.lastPathComponent == preferred } ?? imports.first
            selectedGame = game?.url.lastPathComponent ?? ""
            error = game == nil ? result.1 : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func launchGame(_ selected: GameFiles) {
        guard dmc4_ios_runtime_available(), !busy else { return }
        busy = true
        error = nil

        let scale = Int32(resolutionScale)
        let fps = Int32(frameRate)
        let vol = Float(masterVolume)
        let mute = muteAudio
        let touch = touchControls
        let vibrate = controllerVibration
        let debugLog = debugLogging
        let gamePath = selected.url.path
        let documentsPath = documents.path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? documents
        let userDataDir = appSupport.appendingPathComponent("dmc4", isDirectory: true).path
        let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? documents
        let cacheDir = cachesBase.appendingPathComponent("dmc4", isDirectory: true).path

        DispatchQueue.main.async {
            var errBuf = [CChar](repeating: 0, count: 512)
            let ok = gamePath.withCString { gPtr in
                userDataDir.withCString { uPtr in
                    cacheDir.withCString { cPtr in
                        documentsPath.withCString { dPtr in
                            var cfg = Dmc4IosLaunchConfig(
                                game_path: gPtr,
                                user_data_dir: uPtr,
                                cache_dir: cPtr,
                                documents_dir: dPtr,
                                resolution_scale: scale,
                                frame_rate: fps,
                                master_volume: vol,
                                mute_audio: mute,
                                touch_controls: touch,
                                controller_vibration: vibrate,
                                debug_logging: debugLog
                            )
                            return dmc4_ios_launch(&cfg, &errBuf, Int32(errBuf.count))
                        }
                    }
                }
            }
            busy = false
            if !ok {
                let message = String(cString: errBuf)
                error = message.isEmpty ? "DMC4 runtime failed to start." : message
            }
        }
    }
}

private struct SettingsView: View {
    @AppStorage("resolutionScale") private var resolutionScale = 1
    @AppStorage("frameRate") private var frameRate = 60
    @AppStorage("masterVolume") private var masterVolume = 1.0
    @AppStorage("muteAudio") private var muteAudio = false
    @AppStorage("touchControls") private var touchControls = true
    @AppStorage("controllerVibration") private var controllerVibration = true
    @AppStorage("debugLogging") private var debugLogging = false
    @State private var controllers: [String] = []

    var body: some View {
        Form {
            Section {
                Picker("Resolution scale", selection: $resolutionScale) {
                    Text("1× (Native)").tag(1)
                    Text("2× (Retina)").tag(2)
                }
                Picker("Frame rate cap", selection: $frameRate) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                    Text("120 FPS (ProMotion)").tag(120)
                }
            } header: {
                Text("Graphics")
            } footer: {
                Text("Graphics, audio, and controller vibration settings are applied when the game launches.")
            }

            Section("Audio") {
                Toggle("Mute", isOn: $muteAudio)
                Slider(value: $masterVolume, in: 0...1) {
                    Text("Master volume")
                }
                .disabled(muteAudio)
                LabeledContent("Master volume", value: masterVolume.formatted(.percent.precision(.fractionLength(0))))
            }

            Section {
                Toggle("On-screen touch controls", isOn: $touchControls)
                Toggle("Controller vibration & haptics", isOn: $controllerVibration)
                if !controllers.isEmpty {
                    ForEach(controllers, id: \.self) { name in
                        Label(name, systemImage: "gamecontroller.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                } else {
                    Text("No physical gamepad connected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Controls")
            } footer: {
                Text("Touch controls overlay dual analog sticks, D-Pad, triggers (LT/RT), bumpers (LB/RB), and A/B/X/Y buttons with haptic feedback.")
            }

            Section {
                Toggle("Debug logging", isOn: $debugLogging)
                NavigationLink {
                    LogViewerView()
                } label: {
                    Label("View & Export Logs", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("Diagnostics & Troubleshooting")
            } footer: {
                Text("Logs are automatically written to Files > On My iPhone > Devil May Cry 4 > logs. Enable Debug logging if experiencing crashes or visual glitches.")
            }
        }
        .navigationTitle("Settings")
        .task {
            refreshControllers()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            refreshControllers()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            refreshControllers()
        }
    }

    private func refreshControllers() {
        controllers = GCController.controllers().compactMap { controller in
            guard controller.vendorName != "Virtual Controller" else { return nil }
            return controller.vendorName ?? "Gamepad"
        }
    }
}

// -----------------------------------------------------------------------------
// In-App Log Viewer and Exporter
// -----------------------------------------------------------------------------

private struct LogViewerView: View {
    @State private var logText: String = "Scanning logs directory…"
    @State private var logFiles: [URL] = []
    @State private var selectedLog: URL?
    @State private var filterQuery: String = ""
    @State private var isSharing = false
    @State private var shareURL: URL?
    @State private var showDeleteConfirmation = false
    private let documents = URL.documentsDirectory

    private var logsFolder: URL {
        documents.appendingPathComponent("logs", isDirectory: true)
    }

    private var filteredText: String {
        guard !filterQuery.isEmpty else { return logText }
        let lines = logText.components(separatedBy: .newlines)
        let filtered = lines.filter { $0.localizedCaseInsensitiveContains(filterQuery) }
        return filtered.isEmpty ? "(No lines matched '\(filterQuery)')" : filtered.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            if logFiles.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(logFiles, id: \.self) { url in
                            Button {
                                selectedLog = url
                                loadLog(url)
                            } label: {
                                Text(url.lastPathComponent)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(selectedLog == url ? Color.accentColor : Color(.secondarySystemBackground))
                                    .foregroundStyle(selectedLog == url ? .white : .primary)
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search logs (e.g. error, gpu, vfs)…", text: $filterQuery)
                    .textFieldStyle(.plain)
                if !filterQuery.isEmpty {
                    Button {
                        filterQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.vertical, 8)

            ScrollView {
                Text(filteredText)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .background(Color(.systemBackground))
        }
        .navigationTitle("Diagnostics & Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        if let selectedLog {
                            shareURL = selectedLog
                            isSharing = true
                        }
                    } label: {
                        Label("Share / Export Log", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedLog == nil)

                    Button {
                        UIPasteboard.general.string = filteredText
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                    }

                    Button {
                        refreshLogs()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Clear All Logs", systemImage: "trash")
                    }
                    .disabled(logFiles.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isSharing) {
            if let shareURL {
                ShareActivitySheet(activityItems: [shareURL])
            }
        }
        .confirmationDialog("Delete all log files?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete All Logs", role: .destructive) {
                deleteAllLogs()
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            refreshLogs()
        }
    }

    private func refreshLogs() {
        let fm = FileManager.default
        let folder = logsFolder
        do {
            if !fm.fileExists(atPath: folder.path) {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            let filtered = contents.filter { $0.pathExtension == "log" || $0.pathExtension == "txt" }
            let sorted = filtered.sorted { url1, url2 in
                let d1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let d2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return d1 > d2
            }
            logFiles = sorted
            if let first = sorted.first {
                selectedLog = first
                loadLog(first)
            } else {
                logText = "No logs recorded yet.\n\nLogs will appear here and in the Files app (On My iPhone > Devil May Cry 4 > logs) once you start the game."
            }
        } catch {
            logText = "Failed to list logs: \(error.localizedDescription)"
        }
    }

    private func loadLog(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            if let text = String(data: data, encoding: .utf8) {
                logText = text.isEmpty ? "(Log file is empty)" : text
            } else {
                logText = "(Binary or unreadable log content)"
            }
        } catch {
            logText = "Error reading \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func deleteAllLogs() {
        let fm = FileManager.default
        for file in logFiles {
            try? fm.removeItem(at: file)
        }
        logFiles.removeAll()
        selectedLog = nil
        logText = "All logs cleared."
    }
}

private struct ShareActivitySheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
