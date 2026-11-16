// Shadow Complex Recomp launcher: finds the user's Steam copy of the game, recompiles it to a native
// Apple Silicon app (tools/launcher_build.sh, from the sources bundled in Resources/src), and launches it
// with the chosen runtime settings. Built by launcher/package.sh.
import AppKit
import CryptoKit
import SwiftUI

let gameRelPath = "steamapps/common/Shadow Complex Remastered/Shadow Complex Remastered.app/Contents"
let builtAppRel = "build/Shadow Complex Remastered.app"
let fm = FileManager.default
let supportDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ShadowComplexRecomp")
let srcDir = supportDir.appendingPathComponent("src")
let logDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ShadowComplexRecomp")
let bundledSrc = Bundle.main.resourceURL!.appendingPathComponent("src")

enum GameState: Equatable { case checking, missing, unsupported, ok }
enum BuildState: Equatable { case notBuilt, outdated, building, built, failed(String) }

@MainActor
final class Model: ObservableObject {
    @Published var gamePath: String = UserDefaults.standard.string(forKey: "gamePath") ?? ""
    @Published var gameState: GameState = .checking
    @Published var build: BuildState = .notBuilt
    @Published var step = ""
    @Published var progress: Double? = nil
    @Published var buildLog = ""
    @Published var toolsInstalled = true
    @Published var running = false
    @Published var lastExit: String? = nil
    private var gameHash = ""
    private var game: Process?

    // settings
    @AppStorage("renderer") var renderer = "metal"
    @AppStorage("screen") var screen = ""
    @AppStorage("fillScreen") var fillScreen = false
    @AppStorage("upscaler") var upscaler = "metalfx"
    @AppStorage("noVsync") var noVsync = false
    @AppStorage("testProfile") var testProfile = false
    @AppStorage("skipIntro") var skipIntro = false
    @AppStorage("extraEnv") var extraEnv = ""

    var version: String { (try? String(contentsOf: bundledSrc.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev" }
    var stampURL: URL { supportDir.appendingPathComponent("build.stamp") }
    var builtExe: URL { srcDir.appendingPathComponent(builtAppRel).appendingPathComponent("Contents/MacOS/ShadowComplexRemastered") }
    var gameLog: URL { logDir.appendingPathComponent("game.log") }

    init() {
        toolsInstalled = Model.commandLineToolsInstalled()
        if gamePath.isEmpty || !fm.fileExists(atPath: gamePath) { gamePath = Model.findGame() ?? "" }
        checkGame()
    }

    // ---- game ----
    static func findGame() -> String? {
        let steam = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        var libraries = [steam.path]
        if let vdf = try? String(contentsOf: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for line in vdf.split(separator: "\n") where line.contains("\"path\"") {
                let parts = line.split(separator: "\"")
                if parts.count >= 4 { libraries.append(String(parts[3])) }
            }
        }
        return libraries.map { ($0 as NSString).appendingPathComponent(gameRelPath) }
            .first { fm.fileExists(atPath: ($0 as NSString).appendingPathComponent("MacOS/ShadowComplexRemastered")) }
    }

    func chooseGame() {
        let panel = NSOpenPanel()
        panel.message = "Choose “Shadow Complex Remastered.app” from your Steam library"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: gamePath.isEmpty ? "/Applications" : (gamePath as NSString).deletingLastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        gamePath = url.appendingPathComponent("Contents").path
        checkGame()
    }

    func checkGame() {
        UserDefaults.standard.set(gamePath, forKey: "gamePath")
        let exe = (gamePath as NSString).appendingPathComponent("MacOS/ShadowComplexRemastered")
        guard !gamePath.isEmpty, fm.fileExists(atPath: exe) else { gameState = .missing; updateBuildState(); return }
        gameState = .checking
        let expected = Model.expectedHash()
        Task.detached {
            let hash = Model.sha256(of: URL(fileURLWithPath: exe))
            await MainActor.run {
                self.gameHash = hash
                self.gameState = hash == expected ? .ok : .unsupported
                self.updateBuildState()
            }
        }
    }

    static func expectedHash() -> String {
        let s = (try? String(contentsOf: bundledSrc.appendingPathComponent("tools/orig.sha256"), encoding: .utf8)) ?? ""
        return String(s.split(separator: " ").first ?? "")
    }

    nonisolated static func sha256(of url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 22), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func commandLineToolsInstalled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-f", "clang"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    func installCommandLineTools() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["--install"]
        try? p.run()
    }

    // ---- build ----
    func updateBuildState() {
        if case .building = build { return }
        let stamp = (try? String(contentsOf: stampURL, encoding: .utf8)) ?? ""
        if !fm.fileExists(atPath: builtExe.path) { build = .notBuilt }
        else { build = stamp == "\(version) \(gameHash)" ? .built : .outdated }
    }

    // copy the bundled sources into Application Support (keeping the Python environment and shader cache)
    private func installSources() throws {
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: srcDir.path) where item != "venv" {
            try fm.removeItem(at: srcDir.appendingPathComponent(item))
        }
        for item in try fm.contentsOfDirectory(atPath: bundledSrc.path) {
            try fm.copyItem(at: bundledSrc.appendingPathComponent(item), to: srcDir.appendingPathComponent(item))
        }
    }

    func startBuild() {
        guard gameState == .ok else { return }
        build = .building; step = "Preparing"; progress = nil; buildLog = ""
        do { try installSources() } catch { build = .failed("Could not copy the sources: \(error.localizedDescription)"); return }
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("build.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let logFile = try? FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [srcDir.appendingPathComponent("tools/launcher_build.sh").path, gamePath]
        p.currentDirectoryURL = srcDir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var pending = ""
        var lastError: String? = nil
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            logFile?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                pending += text
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl])
                    pending.removeSubrange(...nl)
                    self.handle(line, &lastError)
                }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            try? logFile?.close()
            Task { @MainActor in
                if proc.terminationStatus == 0 && fm.fileExists(atPath: self.builtExe.path) {
                    try? "\(self.version) \(self.gameHash)".write(to: self.stampURL, atomically: true, encoding: .utf8)
                    self.build = .built
                } else {
                    self.build = .failed(lastError ?? "The build failed (see the build log)")
                }
                self.progress = nil
            }
        }
        do { try p.run() } catch { build = .failed(error.localizedDescription) }
    }

    private func handle(_ line: String, _ lastError: inout String?) {
        if line.hasPrefix("STEP ") { step = String(line.dropFirst(5)); progress = nil }
        else if line.hasPrefix("PROGRESS ") {
            let n = line.split(separator: " ").compactMap { Double($0) }
            if n.count == 2, n[1] > 0 { progress = n[0] / n[1] }
        } else if line.hasPrefix("ERROR ") { lastError = String(line.dropFirst(6)) }
        if headless { print(line); fflush(stdout) }
        buildLog += line + "\n"
        if buildLog.count > 200_000 { buildLog = String(buildLog.suffix(100_000)) }
    }

    // ---- launch ----
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["RT_FPS"] = "1"
        env["SCR_GAME_BINARY"] = (gamePath as NSString).appendingPathComponent("MacOS/ShadowComplexRemastered")
        if renderer == "metal" { env["RT_METAL"] = "1" }
        if !screen.isEmpty { env["RT_SCREEN"] = screen }
        if fillScreen { env["RT_FILL_SCREEN"] = "1" }
        if upscaler == "bilinear" { env["RT_METAL_UPSCALE"] = "bilinear" }
        if noVsync { env["RT_NOVSYNC"] = "1" }
        if testProfile { env["RT_TEST_PROFILE"] = "1" }
        for pair in extraEnv.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { env[String(kv[0])] = String(kv[1]) }
        }
        return env
    }

    func play() {
        guard build == .built, !running else { return }
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        fm.createFile(atPath: gameLog.path, contents: nil)
        let p = Process()
        p.executableURL = builtExe
        p.currentDirectoryURL = builtExe.deletingLastPathComponent()
        p.environment = environment()
        // -nomovie: the engine uses its no-movie player, so the startup logo sequence is skipped
        p.arguments = skipIntro ? ["-nomovie"] : []
        if let h = try? FileHandle(forWritingTo: gameLog) { p.standardOutput = h; p.standardError = h }
        p.terminationHandler = { proc in
            Task { @MainActor in
                self.running = false
                self.lastExit = proc.terminationStatus == 0 ? nil : "The game quit unexpectedly (status \(proc.terminationStatus)). The log has details."
            }
        }
        do { try p.run(); running = true; lastExit = nil; game = p } catch { lastExit = error.localizedDescription }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shadow Complex Remastered").font(.title2).bold()
                Text("Native Apple Silicon recompilation · \(m.version)").foregroundStyle(.secondary)
            }
            if !m.toolsInstalled {
                GroupBox {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Building needs Apple’s Command Line Tools.")
                        Spacer()
                        Button("Install…") { m.installCommandLineTools() }
                        Button("Check Again") { m.toolsInstalled = Model.commandLineToolsInstalled() }
                    }
                }
            }
            GroupBox("Game") { gameSection.frame(maxWidth: .infinity, alignment: .leading) }
            GroupBox("Build") { buildSection.frame(maxWidth: .infinity, alignment: .leading) }
            GroupBox("Settings") { settingsSection.frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button("Game Log") { m.reveal(m.gameLog) }.disabled(!fm.fileExists(atPath: m.gameLog.path))
                if let e = m.lastExit { Text(e).foregroundStyle(.red).font(.callout) }
                Spacer()
                Button(m.running ? "Running…" : "Play") { m.play() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(m.build != .built || m.running)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    @ViewBuilder var gameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch m.gameState {
                case .checking: ProgressView().controlSize(.small); Text("Checking…")
                case .missing: Label("Not found. Install it with Steam, or choose it.", systemImage: "questionmark.circle").foregroundStyle(.orange)
                case .unsupported: Label("This version of the game isn’t supported.", systemImage: "xmark.octagon").foregroundStyle(.red)
                case .ok: Label("Supported version", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Choose…") { m.chooseGame() }
            }
            if !m.gamePath.isEmpty {
                Text((m.gamePath as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder var buildSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch m.build {
                case .notBuilt: Text("Not built yet. Building takes a few minutes.")
                case .outdated: Text("Needs rebuilding (the launcher or the game was updated).").foregroundStyle(.orange)
                case .building: Text(m.step + "…")
                case .built: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let why): Label(why, systemImage: "xmark.octagon").foregroundStyle(.red).lineLimit(3)
                }
                Spacer()
                Button(m.build == .built ? "Rebuild" : "Build") { m.startBuild() }
                    .disabled(m.gameState != .ok || !m.toolsInstalled || m.build == .building || m.running)
            }
            if m.build == .building {
                if let p = m.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
            }
            DisclosureGroup("Build log", isExpanded: $showLog) {
                ScrollView {
                    Text(m.buildLog.isEmpty ? "(empty)" : m.buildLog)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 140)
            }
        }
    }

    @ViewBuilder var settingsSection: some View {
        Form {
            Picker("Renderer", selection: $m.renderer) {
                Text("Metal (recommended)").tag("metal")
                Text("OpenGL").tag("gl")
            }
            Picker("Display", selection: $m.screen) {
                Text("Main display").tag("")
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
            }
            Picker("Upscaling", selection: $m.upscaler) {
                Text("MetalFX").tag("metalfx")
                Text("Bilinear").tag("bilinear")
            }.disabled(m.renderer != "metal")
            Toggle("Skip the intro logos", isOn: $m.skipIntro)
            Toggle("Fill screens narrower than 16:9 (no letterbox)", isOn: $m.fillScreen)
            Toggle("Turn off vertical sync", isOn: $m.noVsync)
            Toggle("Test profile (separate saves)", isOn: $m.testProfile)
            TextField("Extra environment", text: $m.extraEnv, prompt: Text("NAME=value …"))
            Text("Resolution, anti-aliasing and other game options are in the game’s own Settings menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// command line: --build (build or rebuild, printing the build output) and --play (launch with the saved
// settings and wait for the game to exit); otherwise the window
var headless = false

@main
enum Main {
    static func main() async {
        let args = CommandLine.arguments
        guard args.contains("--build") || args.contains("--play") else { LauncherApp.main(); return }
        headless = true
        let m = Model()
        while m.gameState == .checking { try? await Task.sleep(nanoseconds: 100_000_000) }
        print("game: \(m.gamePath) (\(m.gameState))")
        if args.contains("--build") {
            m.startBuild()
            while m.build == .building { try? await Task.sleep(nanoseconds: 200_000_000) }
            print("build: \(m.build)")
            if m.build != .built { exit(1) }
        }
        if args.contains("--play") {
            m.play()
            print(m.running ? "playing (log: \(m.gameLog.path))" : "could not start: \(m.lastExit ?? "not built")")
            while m.running { try? await Task.sleep(nanoseconds: 500_000_000) }
            if let e = m.lastExit { print(e); exit(1) }
        }
        exit(0)
    }
}

struct LauncherApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("Shadow Complex Recomp") { ContentView().environmentObject(model) }
            .windowResizability(.contentSize)
    }
}
