import SwiftUI
import AppKit

#if !TESTING
@main
struct LiveTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("EchoFlow") {
            MainView(model: model)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 820, height: 650)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.recording || model.pendingCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "结束本次录音并退出？"
        alert.informativeText = "已保存的录音和文字会保留。尚未完成的翻译将标记为失败。"
        alert.addButton(withTitle: "继续使用")
        alert.addButton(withTitle: "退出")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.shutdown()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var showKey = false
    @State private var showDirectory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EchoFlow").font(.system(size: 28, weight: .semibold))
                    Text("英语听见 · 中文看见").foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.recording ? "录音中" : "本地收音", systemImage: model.recording ? "record.circle.fill" : "waveform")
                    .foregroundStyle(model.recording ? .red : .secondary)
                    .padding(9).background(.quaternary, in: Capsule())
            }

            HStack(spacing: 12) {
                Button {
                    if model.recording { model.stop() }
                    else { Task { await model.start() } }
                } label: {
                    Label(model.recording ? "停止录音" : "开始录音", systemImage: model.recording ? "stop.fill" : "mic.fill")
                        .padding(.horizontal, 12).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.preparing || (!model.recording && model.pendingCount > 0))
                if model.recording {
                    Button {
                        model.togglePause()
                    } label: {
                        Label(model.paused ? "继续录音" : "暂停", systemImage: model.paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.bordered)
                }
                Button("悬浮字幕") { model.showOverlay(revealingControls: true) }
                Button("历史记录") { model.openRecords() }
                Spacer()
                Text(model.elapsedText).monospacedDigit().font(.title3)
            }

            RecordingStatusView(status: model.status, problem: model.problem, pendingCount: model.pendingCount)

            TranscriptView(model: model, dark: false)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))

            DisclosureGroup("默认保存目录", isExpanded: $showDirectory) {
                HStack {
                    Text(model.defaultDirectory?.path ?? "尚未设置，首次开始录音时选择")
                        .font(.caption).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("选择目录…") { model.chooseDefaultDirectory() }
                }.padding(.top, 8)
            }

            DisclosureGroup("DeepSeek API 密钥", isExpanded: $showKey) {
                HStack {
                    SecureField("输入密钥，保存到本机钥匙串", text: $key)
                    Button("保存密钥") {
                        model.saveKey(key)
                        key = ""
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.recording)
                }.padding(.top, 8)
            }
            Text("\(model.engineLabel) · 单个 WAV · 每 5 秒恢复保护 · TXT / SRT")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(26).frame(minWidth: 680, minHeight: 570)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .history: HistoryView(model: model)
            case .name: RecordingNameView(model: model)
            }
        }
    }
}

struct RecordingStatusView: View {
    let status: String
    let problem: String?
    let pendingCount: Int

    var body: some View {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: problem == nil ? "info.circle" : "exclamationmark.triangle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(problem ?? status).textSelection(.enabled)
                    Text("待处理：\(pendingCount) 段")
                        .font(.caption).foregroundStyle(.secondary)
                        .opacity(pendingCount > 0 ? 1 : 0)
                        .accessibilityHidden(pendingCount == 0)
                }
                Spacer()
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(problem == nil ? Color.accentColor.opacity(0.07) : Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    var dark: Bool
    var showOriginal = true
    var translationFontSize: Double?
    @State private var following = true
    @State private var historySnapshot: [Caption]?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 4) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.captions.isEmpty {
                            Text(showOriginal ? "等待英语语音…" : "等待中文译文…").padding(.vertical, 24)
                        }
                        ForEach(historySnapshot ?? model.captions) { row in
                            VStack(alignment: .leading, spacing: 6) {
                                if showOriginal {
                                    HStack(spacing: 10) {
                                        Text(srtTime(row.start)).monospacedDigit()
                                        Text(row.status == "pending" ? "校对中" : (row.isFinal ? "可后续修订" : "草稿"))
                                        if row.uncertain { Text("含不确定内容").foregroundStyle(.orange) }
                                    }.font(.caption).opacity(0.65)
                                    Text(row.english)
                                        .font(.system(size: translationFontSize.map { max(14, $0 - 6) } ?? (dark ? 17 : 16)))
                                        .opacity(0.75)
                                }
                                Text(row.chinese.isEmpty ? (row.status == "failed" ? "翻译失败，英文已保存" : "正在校对翻译…") : row.chinese)
                                    .font(.system(size: translationFontSize ?? (dark ? 23 : 19), weight: .medium))
                                    .foregroundStyle(row.status == "failed" ? Color.orange : (dark ? Color.white : Color.primary))
                            }.textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting, following {
                        following = false
                        // Freeze the viewed text so later corrections cannot shift the reading position.
                        historySnapshot = model.captions
                    }
                }
                .onChange(of: model.scrollVersion) {
                    if following { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.directory) {
                    following = true
                    historySnapshot = nil
                }
                .onAppear { if following { proxy.scrollTo("bottom", anchor: .bottom) } }
                if !following {
                    Button("回看中 · 回到最新字幕 ↓") {
                        following = true
                        historySnapshot = nil
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }.buttonStyle(.plain).padding(8)
                }
            }
        }.foregroundStyle(dark ? Color.white : Color.primary)
    }
}

struct OverlayView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if !model.overlayControlsHidden {
            HStack {
                    Circle().fill(model.paused ? Color.orange : (model.recording ? Color.red : Color.gray)).frame(width: 7, height: 7)
                    Text(model.paused ? "暂停" : (model.recording ? "LIVE" : "字幕")).font(.caption)
                Spacer()
                Picker("字幕", selection: $model.overlayShowOriginal) {
                    Text("中英").tag(true)
                    Text("仅译文").tag(false)
                }.pickerStyle(.segmented).frame(width: 132)
                Slider(value: $model.overlayFontSize, in: 16...44, step: 1) {
                    Text("字号")
                }.frame(width: 116)
                Text("\(Int(model.overlayFontSize))").monospacedDigit().font(.caption)
                Button { model.hideOverlayControls() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).help("隐藏控制栏")
                Button { model.hideOverlay() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }.foregroundStyle(.white.opacity(0.65)).padding(14)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(model.paused ? Color.orange : (model.recording ? Color.red : Color.gray)).frame(width: 6, height: 6)
                    Text(model.paused ? "暂停" : (model.recording ? "LIVE" : "字幕")).font(.caption2)
                    Button { model.showOverlay(revealingControls: true) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain).help("显示控制栏")
                }
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            TranscriptView(model: model, dark: true, showOriginal: model.overlayShowOriginal,
                           translationFontSize: model.overlayFontSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.87))
    }
}

struct RecordingNameView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("为本次录音命名").font(.title2.bold())
            Text("可跳过，默认使用日期时间。剩余字幕会继续在后台处理。")
                .foregroundStyle(.secondary)
            TextField("录音名称", text: $model.recordingName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.saveRecordingName() }
            HStack {
                Spacer()
                Button("跳过") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("保存名称") { model.saveRecordingName() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440)
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?
    @State private var rows: [Caption] = []
    @State private var readError: String?

    private var selected: RecordingEntry? { model.historyEntries.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("历史记录").font(.title2.bold())
                Spacer()
                Button("刷新") { model.reloadHistory(); loadSelection() }
                Button("完成") { model.sheet = nil }.keyboardShortcut(.cancelAction)
            }
            Text(model.defaultDirectory?.path ?? "请先设置默认保存目录")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if let error = model.historyError { Text(error).foregroundStyle(.orange) }
            if model.defaultDirectory == nil {
                Button("选择默认保存目录…") { model.chooseDefaultDirectory() }
            }
            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.historyEntries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).lineLimit(2)
                            Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(entry.id)
                    }
                }.frame(width: 235)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let entry = selected {
                        HStack {
                            Text(entry.title).font(.headline).textSelection(.enabled)
                            Spacer()
                            Button("在 Finder 中打开") { NSWorkspace.shared.open(entry.directory) }
                        }
                        if let error = readError { Text(error).foregroundStyle(.orange) }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                if rows.isEmpty && readError == nil { Text("这条记录尚无字幕。") }
                                ForEach(rows) { row in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(srtTime(row.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Text(row.english).foregroundStyle(.secondary)
                                        Text(row.chinese.isEmpty ? "[暂无译文]" : row.chinese).font(.system(size: 18))
                                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(8)
                        }
                    } else {
                        Text(model.historyEntries.isEmpty ? "默认目录下还没有录音记录。" : "选择一条记录查看中英字幕")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(.leading, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(22).frame(width: 860, height: 570)
        .onChange(of: selection) { loadSelection() }
        .onChange(of: model.defaultDirectory) { selection = nil; rows = [] }
    }

    private func loadSelection() {
        rows = []
        readError = nil
        guard let entry = selected else { return }
        do { rows = try RecordLibrary.captions(in: entry.directory) }
        catch { readError = "无法读取记录：\(error.localizedDescription)" }
    }
}
