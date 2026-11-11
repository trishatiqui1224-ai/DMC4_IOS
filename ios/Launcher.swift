import SwiftUI
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
    @State private var game: GameFiles?
    @State private var showImporter = false
    @State private var busy = false
    @State private var error: String?
    @State private var imports: [GameFiles] = []
    private let documents = URL.documentsDirectory

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Devil May Cry 4")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Xbox 360")
                            .foregroundStyle(.secondary)
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
                        Label("Settings", systemImage: "gearshape")
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
            .task { await scan() }
            .onChange(of: selectedGame) { selected in
                game = imports.first { $0.url.lastPathComponent == selected }
            }
        }
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
        let gamePath = selected.url.path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? documents
        let userDataDir = appSupport.appendingPathComponent("dmc4", isDirectory: true).path
        let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? documents
        let cacheDir = cachesBase.appendingPathComponent("dmc4", isDirectory: true).path

        DispatchQueue.main.async {
            var errBuf = [CChar](repeating: 0, count: 512)
            let ok = gamePath.withCString { gPtr in
                userDataDir.withCString { uPtr in
                    cacheDir.withCString { cPtr in
                        var cfg = Dmc4IosLaunchConfig(
                            game_path: gPtr,
                            user_data_dir: uPtr,
                            cache_dir: cPtr,
                            resolution_scale: scale,
                            frame_rate: fps,
                            master_volume: vol,
                            mute_audio: mute,
                            touch_controls: touch,
                            controller_vibration: vibrate
                        )
                        return dmc4_ios_launch(&cfg, &errBuf, Int32(errBuf.count))
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

    var body: some View {
        Form {
            Section {
                Picker("Resolution scale", selection: $resolutionScale) {
                    Text("1×").tag(1)
                    Text("2×").tag(2)
                }
                Picker("Frame rate cap", selection: $frameRate) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
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
            Section("Controls") {
                Toggle("Touch controls", isOn: $touchControls)
                Toggle("Controller vibration", isOn: $controllerVibration)
            }
        }
        .navigationTitle("Settings")
    }
}
