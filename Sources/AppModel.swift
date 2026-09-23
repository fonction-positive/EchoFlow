import SwiftUI
import AppKit
import AVFoundation

enum AppSheet: String, Identifiable {
    case history, name
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var recording = false
    @Published var paused = false
    @Published var preparing = false
    @Published var status = "准备就绪。首次使用请先保存 DeepSeek 密钥。"
    @Published var problem: String?
    @Published var captions: [Caption] = []
    @Published var liveEnglish = ""
    @Published var pendingCount = 0
    @Published var elapsedText = "00:00:00"
    @Published var scrollVersion = 0
    @Published var directory: URL?
    @Published var defaultDirectory: URL?
    @Published var sheet: AppSheet?
    @Published var historyEntries: [RecordingEntry] = []
    @Published var historyError: String?
    @Published var recordingName = ""
    @Published var overlayFontSize = 23.0 {
        didSet { preferences.set(overlayFontSize, forKey: "overlayFontSize") }
    }
    @Published var overlayShowOriginal = true {
        didSet { preferences.set(overlayShowOriginal, forKey: "overlayShowOriginal") }
    }
    @Published var overlayControlsHidden = false {
        didSet { preferences.set(overlayControlsHidden, forKey: "overlayControlsHidden") }
    }
    private let preferences: UserDefaults
    let engineLabel = "Whisper large-v3-turbo · 长上下文 · AI 修订"

    private let audio = AudioCapture()
    private let whisper = LocalWhisper()
    private var store: SessionStore?
    private var key = ""
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var overlay: NSPanel?
    private var startUptime = 0.0
    private var sessionID = UUID()
    private var audioQueue: [AudioPhrase] = []
    private var recognizing = false
    private var translationTask: Task<Void, Never>?
    private var waiting: [UUID] = []
    private var quitting = false
    private var observers: [NSObjectProtocol] = []

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if preferences.object(forKey: "overlayFontSize") != nil {
            overlayFontSize = min(44, max(16, preferences.double(forKey: "overlayFontSize")))
        }
        if preferences.object(forKey: "overlayShowOriginal") != nil {
            overlayShowOriginal = preferences.bool(forKey: "overlayShowOriginal")
        }
        if preferences.object(forKey: "overlayControlsHidden") != nil {
            overlayControlsHidden = preferences.bool(forKey: "overlayControlsHidden")
        }
        if let path = preferences.string(forKey: "defaultRecordingDirectory") {
            defaultDirectory = URL(fileURLWithPath: path, isDirectory: true)
            recoverSavedAudio(in: defaultDirectory!)
        }
        audio.onError = { [weak self] message in
            Task { @MainActor in self?.stop(); self?.problem = message }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.stop()
                self.problem = "电脑即将休眠，本次录音已结束并保存。唤醒后请重新开始。"
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.stop()
                self.problem = "音频设备发生变化，录音已保存。请确认麦克风后重新开始。"
            }
        })
    }

    func saveKey(_ value: String) {
        do {
            try Keychain.save(value.trimmingCharacters(in: .whitespacesAndNewlines))
            problem = nil
            status = "密钥已保存到本机钥匙串。"
        } catch { problem = error.localizedDescription }
    }

    func start() async {
        guard !recording, !preparing, pendingCount == 0, sheet != .name else { return }
        problem = nil
        preparing = true
        defer { preparing = false }
        do {
            key = try Keychain.read()
            guard !key.isEmpty else { problem = "请先在下方输入并保存 DeepSeek API 密钥。"; return }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else {
                problem = "麦克风未授权。请在系统设置 → 隐私与安全性 → 麦克风中允许 EchoFlow。"
                return
            }
            if defaultDirectory == nil { chooseDefaultDirectory() }
            guard let parent = defaultDirectory else { return }
            status = "正在加载本地 Whisper 模型…"
            guard let model = Bundle.main.url(forResource: "ggml-large-v3-turbo", withExtension: "bin") else {
                problem = "应用内缺少模型，请重新运行 build.sh。"
                return
            }
            try await whisper.prepare(model: model)
            store = try SessionStore(parent: parent)
            directory = store!.directory
            captions = []
            audioQueue = []
            waiting = []
            sessionID = UUID()
            let thisSession = sessionID
            audio.onPhrase = { [weak self] phrase in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == thisSession, !self.quitting else { return }
                    self.accept(phrase)
                }
            }
            startUptime = ProcessInfo.processInfo.systemUptime
            try audio.start(directory: store!.directory)
            recording = true
            paused = false
            status = "正在收音，本地识别英语；DeepSeek 上下文校对翻译。"
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "保存实时录音与字幕")
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let seconds = Int(self.audio.duration)
                    self.elapsedText = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                }
            }
        } catch {
            problem = error.localizedDescription
            status = "启动失败"
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        paused = false
        preparing = true
        audio.stop()
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        status = "录音已保存，正在完成剩余识别和翻译。"
        do { try store?.finish(duration: audio.duration) }
        catch { problem = "录音信息保存失败：\(error.localizedDescription)" }
        recordingName = store?.metadata.title ?? ""
        sheet = .name
        // The final audio phrase is delivered asynchronously from the audio queue.
        DispatchQueue.main.async {
            self.preparing = false
            self.refreshPending()
        }
    }

    func togglePause() {
        guard recording else { return }
        do {
            if paused {
                try audio.resume()
                paused = false
                status = "正在继续收音，本地识别英语；DeepSeek 上下文校对翻译。"
            } else {
                try audio.pause()
                paused = true
                status = "录音已暂停，正在显示最后一批字幕。"
            }
        } catch {
            problem = paused ? "无法继续录音：\(error.localizedDescription)" : "无法暂停录音：\(error.localizedDescription)"
        }
    }

    private func accept(_ phrase: AudioPhrase) {
        if let index = audioQueue.firstIndex(where: { $0.id == phrase.id }) {
            audioQueue[index] = phrase
        } else { audioQueue.append(phrase) }
        refreshPending()
        if audioQueue.count > 10, recording {
            stop()
            problem = "识别速度落后于录音，已停止收音并保存录音，正在处理剩余片段。"
        }
        recognizeNext()
    }

    #if TESTING
    // Exercise the actual coordinator with a WAV instead of opening the microphone.
    func replay(file: URL, parent: URL, apiKey: String) async throws {
        key = apiKey
        try await whisper.prepare(model: URL(fileURLWithPath: "models/ggml-large-v3-turbo.bin"))
        store = try SessionStore(parent: parent)
        directory = store!.directory
        try FileManager.default.copyItem(at: file, to: directory!.appendingPathComponent("audio.wav"))
        let input = try AVAudioFile(forReading: file)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
        try input.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        var segmenter = AudioSegmenter()
        startUptime = ProcessInfo.processInfo.systemUptime
        for offset in stride(from: 0, to: samples.count, by: 4000) {
            let end = min(offset + 4000, samples.count)
            let delay = startUptime + Double(end) / 16000 - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            for phrase in segmenter.append(Array(samples[offset..<end])) { accept(phrase) }
        }
        if let last = segmenter.flush() { accept(last) }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while pendingCount > 0, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard pendingCount == 0 else { throw TranslationError.incomplete }
    }
    #endif

    private func recognizeNext() {
        guard !recognizing, !audioQueue.isEmpty, !quitting else { return }
        let phrase = audioQueue.removeFirst()
        recognizing = true
        liveEnglish = "正在本地识别，字幕会随上下文修订…"
        refreshPending()
        let context = RecognitionText.context(from: captions, excluding: phrase.id)
        Task {
            do {
                let english = try await whisper.transcribe(phrase.samples, context: context)
                if !quitting, !english.isEmpty || captions.contains(where: { $0.id == phrase.id }) {
                    let index: Int
                    if let existing = captions.firstIndex(where: { $0.id == phrase.id }) { index = existing }
                    else {
                        captions.append(Caption(id: phrase.id, start: phrase.start, end: phrase.end, english: english))
                        index = captions.count - 1
                    }
                    captions[index].recognize(phrase, english: english)
                    if english.isEmpty {
                        captions[index].chinese = "[未识别清晰语音]"
                        captions[index].status = "done"
                        captions[index].uncertain = true
                    } else if !waiting.contains(phrase.id) { waiting.append(phrase.id) }
                    persist(captions[index])
                    scrollVersion += 1
                    translateNext()
                }
            } catch { problem = error.localizedDescription }
            recognizing = false
            liveEnglish = ""
            refreshPending()
            recognizeNext()
        }
    }

    private func translateNext() {
        guard translationTask == nil, !waiting.isEmpty, !quitting else { refreshPending(); return }
        let id = waiting.removeFirst()
        guard let index = captions.firstIndex(where: { $0.id == id }), !captions[index].rawEnglish.isEmpty else {
            translateNext()
            return
        }
        // Revisit two previous subtitles now that more speech is available.
        let lower = max(0, index - 2)
        let targets = Array(captions[lower...index]).filter { !$0.rawEnglish.isEmpty }
        let history = Array(captions[max(0, lower - 6)..<lower])
        let translator = DeepSeek(key: key)
        translationTask = Task {
            do {
                let results = try await translator.revise(targets: targets, history: history)
                guard !quitting else { return }
                for result in results {
                    guard let current = captions.firstIndex(where: { $0.id == result.id }),
                          captions[current].apply(result) else { continue }
                    if captions[current].firstTokenLatency == nil {
                        captions[current].firstTokenLatency = max(0,
                            ProcessInfo.processInfo.systemUptime - startUptime - captions[current].end)
                    }
                    persist(captions[current])
                }
                scrollVersion += 1
            } catch {
                // Mark only the requested current revision, never a newer draft.
                if !quitting, let current = captions.firstIndex(where: { $0.id == id }),
                   captions[current].revision == targets.last?.revision {
                    captions[current].status = "failed"
                    persist(captions[current])
                    problem = "AI 修订失败：\(error.localizedDescription)。录音和英文已保留。"
                }
            }
            translationTask = nil
            refreshPending()
            translateNext()
        }
        refreshPending()
    }

    private func persist(_ row: Caption) {
        do { try store?.save(row) }
        catch {
            if recording { stop() }
            problem = "文字保存失败，已停止收音：\(error.localizedDescription)"
        }
    }

    private func refreshPending() {
        pendingCount = audioQueue.count + (recognizing ? 1 : 0) + waiting.count + (translationTask == nil ? 0 : 1)
        if !recording && !preparing && pendingCount == 0 && directory != nil {
            status = "本次录音和字幕已保存。"
        }
    }

    func shutdown() {
        stop()
        sheet = nil
        quitting = true
        translationTask?.cancel()
        for index in captions.indices where captions[index].status == "pending" {
            captions[index].status = "failed"
            persist(captions[index])
        }
    }

    func chooseDefaultDirectory() {
        let picker = NSOpenPanel()
        picker.title = "选择默认录音保存目录"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.directoryURL = defaultDirectory
        picker.prompt = "设为默认目录"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        setDefaultDirectory(url)
    }

    func setDefaultDirectory(_ url: URL) {
        preferences.set(url.path, forKey: "defaultRecordingDirectory")
        defaultDirectory = url
        recoverSavedAudio(in: url)
        reloadHistory()
    }

    func saveRecordingName() {
        do {
            try store?.name(recordingName)
            sheet = nil
            reloadHistory()
        } catch { problem = "名称保存失败：\(error.localizedDescription)" }
    }

    func openRecords() {
        reloadHistory()
        sheet = .history
    }

    func reloadHistory() {
        historyError = nil
        historyEntries = []
        guard let root = defaultDirectory else { return }
        do { historyEntries = try RecordLibrary.list(in: root) }
        catch { historyError = "无法读取默认目录：\(error.localizedDescription)" }
    }

    private func recoverSavedAudio(in root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            let count = try AudioCapture.recoverIncompleteSessions(in: root)
            if count > 0 { status = "已从异常中断录音恢复 \(count) 个 WAV 文件。" }
        } catch {
            problem = "无法恢复未完成录音：\(error.localizedDescription)"
        }
    }

    func showOverlay(revealingControls: Bool = false) {
        if revealingControls { overlayControlsHidden = false }
        if overlay == nil {
            let panel = CaptionPanel(contentRect: NSRect(x: 100, y: 100, width: 760, height: 340),
                styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "中英悬浮字幕"
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.minSize = NSSize(width: 480, height: 160)
            panel.contentView = NSHostingView(rootView: OverlayView(model: self))
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 380, y: screen.visibleFrame.minY + 45))
            }
            overlay = panel
        }
        overlay?.makeKeyAndOrderFront(nil)
    }

    func hideOverlay() { overlay?.orderOut(nil) }

    func hideOverlayControls() { overlayControlsHidden = true }
}

final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
