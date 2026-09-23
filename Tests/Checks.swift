import Foundation
import AVFoundation
import AppKit
import SwiftUI

private func check(_ condition: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
    guard condition() else {
        fputs("FAIL at Checks.swift:\(line): \(message)\n", stderr)
        exit(1)
    }
}

@main
struct Checks {
    @MainActor static func main() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--recognition-replay"), CommandLine.arguments.count > index + 3 {
            try await RecognitionReplay.run(file: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
                start: Double(CommandLine.arguments[index + 2])!, end: Double(CommandLine.arguments[index + 3])!)
            return
        }
        try await StreamingChecks.run()
        try await ModelDownloadChecks.storage()
        if let index = CommandLine.arguments.firstIndex(of: "--download-checks"), CommandLine.arguments.count > index + 1 {
            try await ModelDownloadChecks.run(server: URL(string: CommandLine.arguments[index + 1])!)
        }
        if CommandLine.arguments.contains("--model-download-smoke") { try await ModelDownloadChecks.officialSmoke() }
        if CommandLine.arguments.contains("--translation-smoke") { try await StreamingChecks.liveSmoke() }
        let statusView = NSHostingView(rootView: RecordingStatusView(status: "正在收音", problem: nil, pendingCount: 0))
        statusView.frame.size.width = 600
        let idleHeight = statusView.fittingSize.height
        statusView.rootView = RecordingStatusView(status: "正在收音", problem: nil, pendingCount: 1)
        statusView.layoutSubtreeIfNeeded()
        let busyHeight = statusView.fittingSize.height
        guard abs(idleHeight - busyHeight) < 0.5 else {
            fputs("FAIL: pending row changes status height: \(idleHeight) → \(busyHeight)\n", stderr)
            exit(1)
        }
        check(srtTime(3661.234) == "01:01:01,234")
        check(srtTime(59.9996) == "00:01:00,000")
        check(srtTime(-1) == "00:00:00,000")
        // Reproduce the live screenshot: one ASR draft expands into many repeated lines.
        let loop = "128 bytes. " + String(repeating: "So it's gonna be 128 bytes. ", count: 20)
        let loopPhrase = AudioPhrase(id: UUID(), revision: 1, isFinal: false,
                                     samples: [], start: 0, end: 3)
        var loopCaption = Caption(id: loopPhrase.id, start: 0, end: 3, english: "")
        loopCaption.recognize(loopPhrase, english: loop)
        check(loopCaption.english == "128 bytes. So it's gonna be 128 bytes.", "A looping draft must not fill the subtitle window")
        check(loopCaption.rawEnglish == loop, "Preserve unmodified recognition for diagnosis")
        check(loopCaption.uncertain, "Loop removal must be marked uncertain")
        for ordinary in ["", "No, no, no.", "  Keep original spacing.\n",
                         String(repeating: "So it's gonna be 128 bytes. ", count: 3),
                         (1...40).map { "The result is \($0) bytes." }.joined(separator: " ")] {
            check(RecognitionText.removingLoops(ordinary) == ordinary, "Normal repetition and changing numbers must remain intact")
        }
        let noisyLoop = "Introduction. " + String(repeating: "So IT'S gonna be 128 bytes!\nso it's gonna be 128 bytes.\n", count: 4) + "Next: 256 bytes."
        check(RecognitionText.removingLoops(noisyLoop) == "Introduction. So IT'S gonna be 128 bytes!\nNext: 256 bytes.")
        let twoLoops = String(repeating: "Alpha beta gamma delta. ", count: 7) + "Middle. " + String(repeating: "One two three four. ", count: 7) + "End."
        check(RecognitionText.removingLoops(twoLoops) == "Alpha beta gamma delta. Middle. One two three four. End.")
        let correctedLoop = CaptionCorrection(id: loopCaption.id, revision: 1, english: loop,
                                             chinese: "所以它会是 128 字节。", uncertain: false)
        check(loopCaption.apply(correctedLoop) && loopCaption.english.count < 80 && loopCaption.uncertain)
        let normalFinal = AudioPhrase(id: loopPhrase.id, revision: 2, isFinal: true, samples: [], start: 0, end: 6)
        loopCaption.recognize(normalFinal, english: "So it's gonna be 128 bytes. Next, 256 bytes.")
        check(loopCaption.isFinal && !loopCaption.uncertain && loopCaption.english.contains("256"))
        check(!loopCaption.apply(correctedLoop), "Old revisions must remain blocked after loop filtering")
        var goodContext = Caption(start: 0, end: 10, english: "")
        goodContext.rawEnglish = "CUDA warps and memory coalescing."
        goodContext.isFinal = true
        var contaminatedContext = Caption(start: 10, end: 20, english: "")
        contaminatedContext.rawEnglish = loop
        contaminatedContext.isFinal = true
        let nextID = UUID()
        var shortLoopContext = goodContext
        shortLoopContext.rawEnglish = String(repeating: "I will show you the details. ", count: 3)
        check(RecognitionText.context(from: [goodContext, shortLoopContext], excluding: nextID) == goodContext.rawEnglish,
              "Three-sentence decoder loops must not become the next audio prompt")
        check(lt_repetition_candidate("I'm sorry. I'm sorry. I'm sorry."))
        check(lt_repetition_candidate("This side. This side? This side."))
        check(lt_repetition_candidate("I will show you the details. I will show you the details."))
        check(!lt_repetition_candidate("No, no, no. Turn left, then turn left again."))
        check(!lt_repetition_candidate("The result is 128 bytes. The result is 256 bytes. The result is 512 bytes."))
        check(RecognitionText.context(from: [goodContext, contaminatedContext], excluding: nextID) == goodContext.rawEnglish,
              "Keep valid terminology but exclude the entire looping source")
        check(RecognitionText.context(from: [goodContext], excluding: goodContext.id).isEmpty,
              "A segment must never prompt its own later draft")
        var recoveredContext = Caption(start: 20, end: 30, english: "")
        recoveredContext.rawEnglish = "Each thread accesses a different element."
        recoveredContext.isFinal = true
        check(RecognitionText.context(from: [goodContext, contaminatedContext, recoveredContext], excluding: nextID) == recoveredContext.rawEnglish,
              "New valid context must resume automatically without using older stale text")
        check(RecognitionText.context(from: [goodContext, recoveredContext], excluding: nextID) == goodContext.rawEnglish + " " + recoveredContext.rawEnglish)
        print("PASS: looping draft reproduction, raw text preservation, ordinary repetition, multiple loops, final revision and stale-response protection")
        let ignored = try StreamEvent.parse(": keepalive")
        let finished = try StreamEvent.parse("data: [DONE]")
        let text = try StreamEvent.parse("data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}")
        check(ignored == .ignored && finished == .finished && text == .text("你好"))
        do {
            _ = try StreamEvent.parse("data: {\"choices\":[{\"finish_reason\":\"length\"}]}")
            fatalError("Truncated translations must fail")
        } catch TranslationError.incomplete {}

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let interrupted = root.appendingPathComponent("interrupted")
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try Data([0, 0, 1, 0, 2, 0, 3, 0]).write(to: interrupted.appendingPathComponent("recording-recovery.pcm"))
        let recovery = AudioRecoveryState(sampleRate: 16_000, channels: 1, frames: 4)
        try JSONEncoder().encode(recovery).write(to: interrupted.appendingPathComponent("recording-recovery.json"))
        let recoveredCount = try AudioCapture.recoverIncompleteSessions(in: root)
        check(recoveredCount == 1)
        let recovered = try AVAudioFile(forReading: interrupted.appendingPathComponent("audio.wav"))
        check(recovered.length == 4)
        check(!FileManager.default.fileExists(atPath: interrupted.appendingPathComponent("recording-recovery.pcm").path))
        check(!FileManager.default.fileExists(atPath: interrupted.appendingPathComponent("recording-recovery.json").path))
        let store = try SessionStore(parent: root)
        var later = Caption(start: 3, end: 5, english: "Second phrase")
        let first = Caption(start: 0, end: 2, english: "First phrase")
        try store.save(later)
        try store.save(first)
        later.chinese = "第二段"
        later.status = "done"
        try store.save(later)
        check(store.captions.count == 2)
        let srt = try String(contentsOf: store.directory.appendingPathComponent("bilingual.srt"), encoding: .utf8)
        check(srt.hasPrefix("1\n00:00:00,000 --> 00:00:02,000\nFirst phrase"))
        check(srt.contains("第二段"))
        let journal = try String(contentsOf: store.directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        check(journal.split(separator: "\n").count == 3)

        // Naming must not move an active session directory or disrupt later AI writes.
        let originalDirectory = store.directory
        try store.finish(duration: 127.6)
        try store.name("  算法课程 / 第二讲  ")
        later.chinese = "命名后仍可保存修订"
        try store.save(later)
        let metadata = try JSONDecoder().decode(RecordingMetadata.self,
            from: Data(contentsOf: store.directory.appendingPathComponent("session.json")))
        check(metadata.title == "算法课程 / 第二讲" && metadata.duration == 127.6 && metadata.endedAt != nil)
        check(store.directory == originalDirectory)
        let listed = try RecordLibrary.list(in: root)
        check(listed.count == 1 && listed[0].title == metadata.title)
        let loaded = try RecordLibrary.captions(in: originalDirectory)
        check(loaded.count == 2 && loaded[1].chinese == later.chinese)
        try store.name("   ")
        check(store.metadata.title == RecordingMetadata.defaultTitle(at: store.metadata.createdAt))
        let legacy = root.appendingPathComponent("LiveTranslate_2026-09-16_15-09-05_E432")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let oldJSON = "{\"id\":\"\(UUID().uuidString)\",\"start\":0,\"end\":2,\"english\":\"Old English\",\"chinese\":\"旧记录\",\"status\":\"done\"}"
        try (oldJSON + "\n{truncated").write(to: legacy.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        let oldRows = try RecordLibrary.captions(in: legacy)
        check(oldRows.count == 1 && oldRows[0].rawEnglish == "Old English" && oldRows[0].isFinal)
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let withLegacy = try RecordLibrary.list(in: root)
        check(withLegacy.count == 2 && withLegacy.contains { $0.directory.lastPathComponent == legacy.lastPathComponent })
        let suite = "local.live-translate.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settingsModel = AppModel(preferences: defaults)
        check(settingsModel.defaultDirectory == nil)
        settingsModel.overlayFontSize = 31
        settingsModel.overlayShowOriginal = false
        settingsModel.overlayControlsHidden = true
        settingsModel.setDefaultDirectory(root)
        let reopenedModel = AppModel(preferences: UserDefaults(suiteName: suite)!)
        check(reopenedModel.defaultDirectory?.path == root.path)
        check(reopenedModel.overlayFontSize == 31 && !reopenedModel.overlayShowOriginal && reopenedModel.overlayControlsHidden)
        reopenedModel.openRecords()
        check(reopenedModel.historyEntries.count == 2 && reopenedModel.sheet == .history)
        print("PASS: fixed status height, saved default directory, recording names, legacy history, latest revision and partial journal recovery")

        var segmenter = AudioSegmenter()
        check(segmenter.append(Array(repeating: 0, count: 16_000)).isEmpty)
        let drafts = segmenter.append(Array(repeating: 0.1, count: 6 * 16_000))
        check(drafts.count == 2 && drafts.allSatisfy { !$0.isFinal })
        check(drafts[0].id == drafts[1].id && drafts[1].samples.count > drafts[0].samples.count)
        // A short pause must not throw away the context needed to repair speech.
        check(segmenter.append(Array(repeating: 0, count: 16_000)).isEmpty)
        let last = segmenter.flush()!
        check(last.isFinal && last.id == drafts[0].id && last.revision > drafts[1].revision)
        check(abs(last.start - 0.8) < 0.001 && abs(last.end - 7) < 0.001)
        check(segmenter.flush() == nil)
        var row = Caption(id: last.id, start: last.start, end: last.end, english: "")
        row.recognize(drafts[0], english: "the moon")
        let obsolete = CaptionCorrection(id: row.id, revision: row.revision, english: "the moon", chinese: "月亮", uncertain: false)
        row.recognize(last, english: "they move")
        check(!row.apply(obsolete), "An old network response must not replace new recognition")
        let correction = CaptionCorrection(id: row.id, revision: row.revision, english: "They move.", chinese: "它们移动。", uncertain: false)
        check(row.apply(correction) && row.rawEnglish == "they move")
        try store.save(row)
        let rawExport = try String(contentsOf: store.directory.appendingPathComponent("english-raw.txt"), encoding: .utf8)
        check(rawExport.contains("they move"))
        let validJSON = String(decoding: try JSONEncoder().encode(CorrectionResponse(rows: [correction])), as: UTF8.self)
        let parsed = try CorrectionResponse.parse(validJSON, targets: [row])
        check(parsed.count == 1)
        for invalid in ["{\"rows\":[]}", String(decoding: try JSONEncoder().encode(CorrectionResponse(rows: [obsolete])), as: UTF8.self)] {
            do { _ = try CorrectionResponse.parse(invalid, targets: [row]); fatalError("Missing/stale AI rows must fail") }
            catch TranslationError.incomplete {}
        }

        // Two-hour accelerated simulation: drafts share IDs, final windows remain
        // bounded, every sample of continuous speech reaches a final revision.
        var long = AudioSegmenter()
        let second = Array(repeating: Float(0.1), count: 16_000)
        var lastEnd = 0.0
        var finalCount = 0
        var seen: [UUID: Int] = [:]
        func checkPhrase(_ phrase: AudioPhrase) {
            check(phrase.samples.count <= 448_000)
            check(phrase.revision > (seen[phrase.id] ?? 0))
            seen[phrase.id] = phrase.revision
            if phrase.isFinal {
                check(abs(phrase.start - lastEnd) < 0.001)
                lastEnd = phrase.end
                finalCount += 1
            }
        }
        for _ in 0..<7200 { for phrase in long.append(second) { checkPhrase(phrase) } }
        if let tail = long.flush() { checkPhrase(tail) }
        check(finalCount == 258 && abs(lastEnd - 7200) < 0.001)
        print("PASS: revision identity, stale-response protection, source preservation, JSON validation, SSE, exports, two-hour simulated segmentation")

        if CommandLine.arguments.contains("--replay") {
            let key = try String(contentsOfFile: "api.env", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            // This fixture file contains only the API key; never print its contents.
            check(!key.isEmpty && !key.contains("\n"))
            let model = AppModel()
            try await model.replay(file: URL(fileURLWithPath: ".build/diagnostic-16k.wav"),
                parent: URL(fileURLWithPath: ".build/replay-next"), apiKey: key)
            check(!model.captions.isEmpty && model.captions.allSatisfy { $0.isFinal && $0.status == "done" })
            check(Set(model.captions.map(\.id)).count == model.captions.count)
            print("PASS: actual AppModel realtime replay, final revisions and API translation drained")
            print("Records: \(model.directory!.path)")
        }

        if CommandLine.arguments.contains("--whisper") {
            let engine = LocalWhisper()
            let modelURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHOFLOW_TEST_MODEL"] ?? "models/ggml-large-v3-turbo.bin")
            try await engine.prepare(model: modelURL)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: ".build/vendor/whisper.cpp-1.8.3/samples/jfk.wav"))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await engine.transcribe(samples)
            let seconds = ProcessInfo.processInfo.systemUptime - started
            check(result.lowercased().contains("country"))
            print(String(format: "PASS: local Whisper %.2f seconds for %.2f seconds audio", seconds, Double(samples.count) / 16_000))
            print(result)
            let silent = try await engine.transcribe(Array(repeating: 0, count: 16_000))
            check(silent.isEmpty)
            print("PASS: silence does not produce subtitles")
            await engine.unload()
            try await engine.prepare(model: modelURL)
            let reloaded = try await engine.transcribe(samples)
            check(reloaded.lowercased().contains("country"))
            print("PASS: unload and reload model after storage management")
        }
    }
}
