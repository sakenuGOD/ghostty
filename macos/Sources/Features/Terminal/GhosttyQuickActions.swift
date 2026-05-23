import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Small native titlebar controls for high-frequency terminal actions.
///
/// This is intentionally macOS-only and lives entirely in the app layer. The
/// terminal surface is only used for final text insertion, so the feature does
/// not require changes to the Zig core.
@MainActor
final class GhosttyQuickActionsModel: ObservableObject {
    static let shared = GhosttyQuickActionsModel()

    struct Language: Identifiable {
        let id: String
        let label: String
    }

    let languages: [Language] = [
        .init(id: "ru_RU", label: "Русский"),
        .init(id: "en_US", label: "English"),
    ]

    let sounds = [
        "Basso",
        "Blow",
        "Bottle",
        "Frog",
        "Funk",
        "Glass",
        "Hero",
        "Morse",
        "Ping",
        "Pop",
        "Purr",
        "Sosumi",
        "Submarine",
        "Tink",
    ]

    let notifyThresholds = [3, 8, 15, 30, 60]
    let dictationDurations = [3, 5, 8, 12]

    @Published var isDictating = false
    @Published var statusText: String?

    @Published var language: String {
        didSet {
            saveString(language, for: Keys.language)
            writeShellSettings()
        }
    }

    @Published var finishSoundEnabled: Bool {
        didSet {
            saveBool(finishSoundEnabled, for: Keys.finishSoundEnabled)
            writeShellSettings()
        }
    }

    @Published var finishSoundName: String {
        didSet {
            saveString(finishSoundName, for: Keys.finishSoundName)
            writeShellSettings()
        }
    }

    @Published var finishSoundThreshold: Int {
        didSet {
            saveInt(finishSoundThreshold, for: Keys.finishSoundThreshold)
            writeShellSettings()
        }
    }

    @Published var dictationSeconds: Int {
        didSet {
            saveInt(dictationSeconds, for: Keys.dictationSeconds)
            writeShellSettings()
        }
    }

    private var speechSession: SpeechSession?

    private enum Keys {
        static let language = "GhosttyQuickActions.language"
        static let finishSoundEnabled = "GhosttyQuickActions.finishSoundEnabled"
        static let finishSoundName = "GhosttyQuickActions.finishSoundName"
        static let finishSoundThreshold = "GhosttyQuickActions.finishSoundThreshold"
        static let dictationSeconds = "GhosttyQuickActions.dictationSeconds"
    }

    private init() {
        let defaults = UserDefaults.standard
        self.language = defaults.string(forKey: Keys.language) ?? "ru_RU"
        self.finishSoundEnabled = if defaults.object(forKey: Keys.finishSoundEnabled) == nil {
            true
        } else {
            defaults.bool(forKey: Keys.finishSoundEnabled)
        }
        self.finishSoundName = defaults.string(forKey: Keys.finishSoundName) ?? "Ping"
        let threshold = defaults.integer(forKey: Keys.finishSoundThreshold)
        self.finishSoundThreshold = threshold == 0 ? 8 : threshold
        let seconds = defaults.integer(forKey: Keys.dictationSeconds)
        self.dictationSeconds = seconds == 0 ? 5 : seconds
        writeShellSettings()
    }

    func startDictation(controllerProvider: @escaping () -> TerminalController?) {
        guard !isDictating else {
            stopDictation()
            return
        }

        isDictating = true
        statusText = "Listening..."
        QuickActionSound.play("Tink")

        let session = SpeechSession(localeIdentifier: language, seconds: TimeInterval(dictationSeconds))
        speechSession = session
        session.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isDictating = false
                self.speechSession = nil

                switch result {
                case .success(let transcript):
                    let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanTranscript.isEmpty else {
                        self.statusText = "No speech"
                        QuickActionSound.play("Basso")
                        return
                    }
                    controllerProvider()?.ghosttyQuickActionsInsertText(cleanTranscript)
                    self.statusText = nil
                    QuickActionSound.play("Pop")

                case .failure(let error):
                    self.statusText = error.localizedDescription
                    QuickActionSound.play("Basso")
                }
            }
        }
    }

    func stopDictation() {
        speechSession?.stop()
        speechSession = nil
        isDictating = false
        statusText = nil
    }

    func chooseFilesAndInsert(controllerProvider: @escaping () -> TerminalController?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Insert"
        panel.message = "Choose files or folders to insert into the focused terminal."
        panel.directoryURL = controllerProvider()?.ghosttyQuickActionsWorkingDirectory

        present(panel, controllerProvider: controllerProvider) { urls in
            let text = urls.map { Ghostty.Shell.escape($0.path) }.joined(separator: " ") + " "
            controllerProvider()?.ghosttyQuickActionsInsertText(text)
        }
    }

    func chooseFilesAndPreview(controllerProvider: @escaping () -> TerminalController?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Preview"
        panel.message = "Choose files or folders to preview with Quick Look."
        panel.directoryURL = controllerProvider()?.ghosttyQuickActionsWorkingDirectory

        present(panel, controllerProvider: controllerProvider) { urls in
            QuickLookLauncher.preview(urls)
        }
    }

    func insertWorkingDirectory(controllerProvider: @escaping () -> TerminalController?) {
        guard let url = controllerProvider()?.ghosttyQuickActionsWorkingDirectory else {
            QuickActionSound.play("Basso")
            return
        }

        controllerProvider()?.ghosttyQuickActionsInsertText(Ghostty.Shell.escape(url.path) + " ")
    }

    func playFinishSound() {
        guard finishSoundEnabled else {
            QuickActionSound.play("Basso")
            return
        }

        QuickActionSound.play(finishSoundName)
    }

    private func present(
        _ panel: NSOpenPanel,
        controllerProvider: @escaping () -> TerminalController?,
        onChoose: @escaping ([URL]) -> Void
    ) {
        if let window = controllerProvider()?.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK else { return }
                onChoose(panel.urls)
            }
        } else if panel.runModal() == .OK {
            onChoose(panel.urls)
        }
    }

    private func writeShellSettings() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("ghostty-tools")

        do {
            try FileManager.default.createDirectory(
                at: configDir,
                withIntermediateDirectories: true)

            let settings = """
            # Generated by Ghostty native quick actions.
            export GHOSTTY_NOTIFY_ENABLED=\(finishSoundEnabled ? "1" : "0")
            export GHOSTTY_NOTIFY_MIN_SECONDS=\(finishSoundThreshold)
            export GHOSTTY_NOTIFY_SOUND=\(finishSoundName)
            export GHOSTTY_DICTATE_SECONDS=\(dictationSeconds)
            export GHOSTTY_DICTATE_LOCALE=\(language)

            """
            try settings.write(
                to: configDir.appendingPathComponent("settings.zsh"),
                atomically: true,
                encoding: .utf8)
        } catch {
            Ghostty.logger.warning("failed to write quick action shell settings: \(error.localizedDescription)")
        }
    }

    private func saveString(_ value: String, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveBool(_ value: Bool, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveInt(_ value: Int, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

struct GhosttyQuickActionsTitlebarView: View {
    let controllerProvider: () -> TerminalController?

    @ObservedObject private var model = GhosttyQuickActionsModel.shared

    var body: some View {
        HStack(spacing: 5) {
            fileMenu
            micButton
            soundMenu
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.trailing, 6)
        .frame(height: 24)
    }

    private var fileMenu: some View {
        Menu {
            Button("Insert File Path...") {
                model.chooseFilesAndInsert(controllerProvider: controllerProvider)
            }

            Button("Preview File...") {
                model.chooseFilesAndPreview(controllerProvider: controllerProvider)
            }

            Divider()

            Button("Insert Working Directory") {
                model.insertWorkingDirectory(controllerProvider: controllerProvider)
            }
        } label: {
            Image(systemName: "folder")
                .frame(width: 22, height: 20)
        }
        .help("Files")
    }

    private var micButton: some View {
        Button {
            model.startDictation(controllerProvider: controllerProvider)
        } label: {
            Image(systemName: model.isDictating ? "mic.fill" : "mic")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.isDictating ? .red : .primary)
                .frame(width: 22, height: 20)
        }
        .help(model.isDictating ? "Stop Dictation" : "Dictate")
    }

    private var soundMenu: some View {
        Menu {
            Picker("Transcription", selection: $model.language) {
                ForEach(model.languages) { language in
                    Text(language.label).tag(language.id)
                }
            }

            Picker("Record", selection: $model.dictationSeconds) {
                ForEach(model.dictationDurations, id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }

            Divider()

            Toggle("Finish Sound", isOn: $model.finishSoundEnabled)

            Picker("Sound", selection: $model.finishSoundName) {
                ForEach(model.sounds, id: \.self) { sound in
                    Text(sound).tag(sound)
                }
            }

            Picker("After", selection: $model.finishSoundThreshold) {
                ForEach(model.notifyThresholds, id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }

            Button("Test Sound") {
                model.playFinishSound()
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 22, height: 20)
        }
        .help("Quick Action Settings")
    }
}

private final class SpeechSession {
    enum SpeechError: LocalizedError {
        case permissionDenied
        case recognizerUnavailable
        case microphoneFailed(String)
        case noTranscript

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Speech or microphone permission denied"
            case .recognizerUnavailable:
                "Speech recognizer unavailable"
            case .microphoneFailed(let message):
                "Microphone failed: \(message)"
            case .noTranscript:
                "No speech transcript"
            }
        }
    }

    private let localeIdentifier: String
    private let seconds: TimeInterval
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var completion: ((Result<String, Error>) -> Void)?
    private var transcript = ""
    private var finished = false

    init(localeIdentifier: String, seconds: TimeInterval) {
        self.localeIdentifier = localeIdentifier
        self.seconds = max(1, seconds)
    }

    func start(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion

        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            guard let self else { return }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async {
                    guard speechStatus == .authorized && micGranted else {
                        self.finish(.failure(SpeechError.permissionDenied))
                        return
                    }

                    self.startRecording()
                }
            }
        }
    }

    func stop() {
        stopCapture()
        finishIfReady()
    }

    private func startRecording() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            finish(.failure(SpeechError.recognizerUnavailable))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                self.transcript = result.bestTranscription.formattedString
            }

            if error != nil || result?.isFinal == true {
                self.finishIfReady()
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            finish(.failure(SpeechError.microphoneFailed(error.localizedDescription)))
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.stopCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.finishIfReady()
            }
        }
    }

    private func stopCapture() {
        request?.endAudio()
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func finishIfReady() {
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTranscript.isEmpty {
            finish(.failure(SpeechError.noTranscript))
        } else {
            finish(.success(cleanTranscript))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        stopCapture()
        task?.cancel()
        task = nil
        request = nil
        completion?(result)
        completion = nil
    }
}

private enum QuickLookLauncher {
    static func preview(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p"] + urls.map(\.path)
        try? process.run()
    }
}

extension TerminalController {
    @MainActor
    var ghosttyQuickActionsWorkingDirectory: URL? {
        guard let pwd = focusedSurface?.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd)
    }

    @MainActor
    func ghosttyQuickActionsInsertText(_ text: String) {
        guard let surface = focusedSurface ?? firstSurface else {
            QuickActionSound.play("Basso")
            return
        }

        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(surface)
        surface.surfaceModel?.sendText(text)
    }

    @MainActor
    private var firstSurface: Ghostty.SurfaceView? {
        for surface in surfaceTree {
            return surface
        }

        return nil
    }
}

private enum QuickActionSound {
    static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}
