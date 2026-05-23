import AppKit
import AVFoundation
import Speech
import SwiftUI
import Translation

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

    @Published var floatOnTopEnabled: Bool
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

    @Published var finishDesktopNotificationEnabled: Bool {
        didSet {
            saveBool(finishDesktopNotificationEnabled, for: Keys.finishDesktopNotificationEnabled)
            writeShellSettings()
        }
    }

    @Published var finishPresentEnabled: Bool {
        didSet {
            saveBool(finishPresentEnabled, for: Keys.finishPresentEnabled)
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
    private var dictationKeyMonitor: Any?
    private var cachedEnglishTranslationSession: Any?

    private enum Keys {
        static let language = "GhosttyQuickActions.language"
        static let finishSoundEnabled = "GhosttyQuickActions.finishSoundEnabled"
        static let finishDesktopNotificationEnabled = "GhosttyQuickActions.finishDesktopNotificationEnabled"
        static let finishPresentEnabled = "GhosttyQuickActions.finishPresentEnabled"
        static let finishSoundName = "GhosttyQuickActions.finishSoundName"
        static let finishSoundThreshold = "GhosttyQuickActions.finishSoundThreshold"
        static let dictationSeconds = "GhosttyQuickActions.dictationSeconds"
    }

    enum QuickActionError: LocalizedError {
        case translationUnavailable
        case emptyTranslation

        var errorDescription: String? {
            switch self {
            case .translationUnavailable:
                "Russian to English translation is unavailable"
            case .emptyTranslation:
                "Translation returned no text"
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.language = defaults.string(forKey: Keys.language) ?? "ru_RU"
        self.finishSoundEnabled = if defaults.object(forKey: Keys.finishSoundEnabled) == nil {
            true
        } else {
            defaults.bool(forKey: Keys.finishSoundEnabled)
        }
        self.finishDesktopNotificationEnabled = if defaults.object(
            forKey: Keys.finishDesktopNotificationEnabled) == nil {
            true
        } else {
            defaults.bool(forKey: Keys.finishDesktopNotificationEnabled)
        }
        self.finishPresentEnabled = defaults.bool(forKey: Keys.finishPresentEnabled)
        self.finishSoundName = defaults.string(forKey: Keys.finishSoundName) ?? "Ping"
        let threshold = defaults.integer(forKey: Keys.finishSoundThreshold)
        self.finishSoundThreshold = threshold == 0 ? 30 : threshold
        let seconds = defaults.integer(forKey: Keys.dictationSeconds)
        self.dictationSeconds = seconds == 0 ? 5 : seconds
        let defaultWindowLevel = UserDefaults.ghostty.value(
            forKey: TerminalWindow.defaultLevelKey) as? NSWindow.Level
        self.floatOnTopEnabled = defaultWindowLevel == .floating
        writeShellSettings()
    }

    func startDictation(controllerProvider: @escaping () -> TerminalController?) {
        guard !isDictating else {
            finishDictation()
            return
        }

        isDictating = true
        let outputLanguage = language
        let inputLanguage = recognitionLocaleIdentifier(for: outputLanguage)
        statusText = outputLanguage == "en_US"
            ? "Recording Russian. Press Enter to translate."
            : "Recording. Press Enter to stop."
        installDictationKeyMonitor()
        QuickActionSound.play("Tink")

        let session = SpeechSession(localeIdentifier: inputLanguage)
        speechSession = session
        session.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isDictating = false
                self.speechSession = nil
                self.removeDictationKeyMonitor()

                switch result {
                case .success(let transcript):
                    let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanTranscript.isEmpty else {
                        self.statusText = "No speech"
                        QuickActionSound.play("Basso")
                        return
                    }
                    do {
                        self.statusText = outputLanguage == "en_US" ? "Translating..." : nil
                        let finalText = try await self.outputText(
                            from: cleanTranscript,
                            outputLanguage: outputLanguage)
                        controllerProvider()?.ghosttyQuickActionsInsertText(finalText)
                        self.statusText = nil
                        QuickActionSound.play("Pop")
                    } catch {
                        self.statusText = error.localizedDescription
                        QuickActionSound.play("Basso")
                    }

                case .failure(let error):
                    self.statusText = error.localizedDescription
                    QuickActionSound.play("Basso")
                }
            }
        }
    }

    func finishDictation() {
        guard isDictating else { return }
        statusText = "Stopping..."
        speechSession?.stop()
    }

    func cancelDictation() {
        guard isDictating else { return }
        speechSession?.cancel()
        speechSession = nil
        isDictating = false
        statusText = "Cancelled"
        removeDictationKeyMonitor()
        QuickActionSound.play("Basso")
    }

    private func installDictationKeyMonitor() {
        removeDictationKeyMonitor()
        dictationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 36, 76:
                Task { @MainActor in self?.finishDictation() }
                return nil
            case 53:
                Task { @MainActor in self?.cancelDictation() }
                return nil
            default:
                return event
            }
        }
    }

    private func removeDictationKeyMonitor() {
        guard let dictationKeyMonitor else { return }
        NSEvent.removeMonitor(dictationKeyMonitor)
        self.dictationKeyMonitor = nil
    }

    func toggleFloatOnTop(controllerProvider: @escaping () -> TerminalController?) {
        guard let window = controllerProvider()?.window else {
            QuickActionSound.play("Basso")
            return
        }

        let nextEnabled = window.level != .floating
        window.level = nextEnabled ? .floating : .normal
        floatOnTopEnabled = nextEnabled

        let defaults = UserDefaults.ghostty
        if nextEnabled {
            defaults.set(NSWindow.Level.floating, forKey: TerminalWindow.defaultLevelKey)
        } else {
            defaults.removeObject(forKey: TerminalWindow.defaultLevelKey)
        }

        QuickActionSound.play(nextEnabled ? "Tink" : "Pop")
    }

    private func recognitionLocaleIdentifier(for outputLanguage: String) -> String {
        outputLanguage == "en_US" ? "ru_RU" : outputLanguage
    }

    private func outputText(from transcript: String, outputLanguage: String) async throws -> String {
        guard outputLanguage == "en_US" else { return transcript }
        return try await translateRussianToEnglish(transcript)
    }

    private func translateRussianToEnglish(_ text: String) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw QuickActionError.translationUnavailable
        }

        let session = englishTranslationSession()
        try await session.prepareTranslation()

        let response = try await session.translate(text)
        let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else {
            throw QuickActionError.emptyTranslation
        }

        return translated
    }

    @available(macOS 26.0, *)
    private func englishTranslationSession() -> TranslationSession {
        if let cachedEnglishTranslationSession = cachedEnglishTranslationSession as? TranslationSession {
            return cachedEnglishTranslationSession
        }

        let session: TranslationSession
        if #available(macOS 26.4, *) {
            session = TranslationSession(
                installedSource: Locale.Language(identifier: "ru"),
                target: Locale.Language(identifier: "en"),
                preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(
                installedSource: Locale.Language(identifier: "ru"),
                target: Locale.Language(identifier: "en"))
        }

        cachedEnglishTranslationSession = session
        return session
    }

    func chooseFilesAndInsertAbsolute(controllerProvider: @escaping () -> TerminalController?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Insert Paths"
        panel.message = "Choose files or folders to insert as absolute paths."
        panel.directoryURL = controllerProvider()?.ghosttyQuickActionsWorkingDirectory

        present(panel, controllerProvider: controllerProvider) { urls in
            let text = urls.map { Ghostty.Shell.escape($0.path) }.joined(separator: " ") + " "
            controllerProvider()?.ghosttyQuickActionsInsertText(text)
        }
    }

    func chooseFilesAndInsertRelative(controllerProvider: @escaping () -> TerminalController?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Insert Relative"
        panel.message = "Choose files or folders to insert relative to the focused terminal."
        let workingDirectory = controllerProvider()?.ghosttyQuickActionsWorkingDirectory
        panel.directoryURL = workingDirectory

        present(panel, controllerProvider: controllerProvider) { urls in
            let text = urls
                .map { Ghostty.Shell.escape(self.relativePath(for: $0, from: workingDirectory)) }
                .joined(separator: " ") + " "
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

    func chooseFilesAndReveal(controllerProvider: @escaping () -> TerminalController?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Reveal"
        panel.message = "Choose files or folders to reveal in Finder."
        panel.directoryURL = controllerProvider()?.ghosttyQuickActionsWorkingDirectory

        present(panel, controllerProvider: controllerProvider) { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func chooseDirectoryAndChange(controllerProvider: @escaping () -> TerminalController?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "cd"
        panel.message = "Choose a folder and run cd in the focused terminal."
        panel.directoryURL = controllerProvider()?.ghosttyQuickActionsWorkingDirectory

        present(panel, controllerProvider: controllerProvider) { urls in
            guard let url = urls.first else { return }
            controllerProvider()?.ghosttyQuickActionsInsertText("cd \(Ghostty.Shell.escape(url.path))\n")
        }
    }

    func insertWorkingDirectory(controllerProvider: @escaping () -> TerminalController?) {
        guard let url = controllerProvider()?.ghosttyQuickActionsWorkingDirectory else {
            QuickActionSound.play("Basso")
            return
        }

        controllerProvider()?.ghosttyQuickActionsInsertText(Ghostty.Shell.escape(url.path) + " ")
    }

    func openWorkingDirectoryInFinder(controllerProvider: @escaping () -> TerminalController?) {
        guard let url = controllerProvider()?.ghosttyQuickActionsWorkingDirectory else {
            QuickActionSound.play("Basso")
            return
        }

        NSWorkspace.shared.open(url)
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

    private func relativePath(for url: URL, from workingDirectory: URL?) -> String {
        guard let workingDirectory else { return url.path }

        let basePath = workingDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == basePath { return "." }
        if path.hasPrefix(basePath + "/") {
            return String(path.dropFirst(basePath.count + 1))
        }

        return path
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
            export GHOSTTY_NOTIFY_DESKTOP=\(finishDesktopNotificationEnabled ? "1" : "0")
            export GHOSTTY_NOTIFY_PRESENT=\(finishPresentEnabled ? "1" : "0")
            export GHOSTTY_NOTIFY_MIN_SECONDS=\(finishSoundThreshold)
            export GHOSTTY_NOTIFY_SOUND=\(finishSoundName)
            export GHOSTTY_DICTATE_SECONDS=\(dictationSeconds)
            export GHOSTTY_DICTATE_LOCALE=\(recognitionLocaleIdentifier(for: language))
            export GHOSTTY_DICTATE_OUTPUT_LOCALE=\(language)
            export GHOSTTY_DICTATE_TRANSLATION_TIMEOUT=6
            export GHOSTTY_FORCE_CLI_COLORS=1

            """
            let settingsURL = configDir.appendingPathComponent("settings.zsh")
            let existingSettings = try? String(contentsOf: settingsURL, encoding: .utf8)
            guard existingSettings != settings else { return }

            try settings.write(
                to: settingsURL,
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
            pinButton
            fileMenu
            micButton
            soundMenu
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.trailing, 6)
        .frame(height: 24)
    }

    private var pinButton: some View {
        Button {
            model.toggleFloatOnTop(controllerProvider: controllerProvider)
        } label: {
            Image(systemName: model.floatOnTopEnabled ? "pin.fill" : "pin")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.floatOnTopEnabled ? Color.accentColor : Color.primary)
                .frame(width: 22, height: 20)
        }
        .help(model.floatOnTopEnabled ? "Floating on Top" : "Float on Top")
    }

    private var fileMenu: some View {
        Menu {
            Button("Insert Absolute Paths...") {
                model.chooseFilesAndInsertAbsolute(controllerProvider: controllerProvider)
            }

            Button("Insert Relative Paths...") {
                model.chooseFilesAndInsertRelative(controllerProvider: controllerProvider)
            }

            Button("Preview with Quick Look...") {
                model.chooseFilesAndPreview(controllerProvider: controllerProvider)
            }

            Button("Reveal in Finder...") {
                model.chooseFilesAndReveal(controllerProvider: controllerProvider)
            }

            Divider()

            Button("Insert Working Directory") {
                model.insertWorkingDirectory(controllerProvider: controllerProvider)
            }

            Button("Open Working Directory") {
                model.openWorkingDirectoryInFinder(controllerProvider: controllerProvider)
            }

            Button("cd to Folder...") {
                model.chooseDirectoryAndChange(controllerProvider: controllerProvider)
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
            Picker("Output Language", selection: $model.language) {
                ForEach(model.languages) { language in
                    Text(language.label).tag(language.id)
                }
            }

            Picker("Shell Fallback Record", selection: $model.dictationSeconds) {
                ForEach(model.dictationDurations, id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }

            Divider()

            Toggle("Finish Sound", isOn: $model.finishSoundEnabled)
            Toggle("Desktop Notification", isOn: $model.finishDesktopNotificationEnabled)
            Toggle("Bring Window Front", isOn: $model.finishPresentEnabled)

            Picker("Sound", selection: $model.finishSoundName) {
                ForEach(model.sounds, id: \.self) { sound in
                    Text(sound).tag(sound)
                }
            }

            Picker("After Running", selection: $model.finishSoundThreshold) {
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
        case cancelled

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
            case .cancelled:
                "Dictation cancelled"
            }
        }
    }

    private let localeIdentifier: String
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var completion: ((Result<String, Error>) -> Void)?
    private var transcript = ""
    private var finished = false

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
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

    func cancel() {
        finish(.failure(SpeechError.cancelled))
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

        // Recording is intentionally open-ended. Return/Enter stops and commits,
        // Escape cancels; see GhosttyQuickActionsModel's local key monitor.
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
