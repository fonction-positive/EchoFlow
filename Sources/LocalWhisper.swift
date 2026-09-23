import Foundation

enum RecognitionError: Error { case unreliable }

struct AudioPhrase {
    let id: UUID
    let revision: Int
    let isFinal: Bool
    let samples: [Float]
    let start: Double
    let end: Double
}

// Keep the same subtitle identity while up to 28 seconds of audio accumulate.
// Short pauses stay inside the window so later recognition can repair drafts.
struct AudioSegmenter {
    private var tail: [Float] = []
    private var preRoll: [Float] = []
    private var phrase: [Float] = []
    private var noise: [Float] = []
    private var threshold: Float = 0.012
    private var position = 0
    private var start = 0
    private var lastVoice = 0
    private var voicedFrames = 0
    private var emittedFrames = 0
    private var id = UUID()
    private var revision = 0

    mutating func append(_ samples: [Float]) -> [AudioPhrase] {
        tail += samples
        var output: [AudioPhrase] = []
        var offset = 0
        while offset + 320 <= tail.count {
            let block = Array(tail[offset..<(offset + 320)])
            offset += 320
            let rms = sqrt(block.reduce(Float(0)) { $0 + $1 * $1 } / 320)
            noise.append(rms)
            if noise.count > 150 { noise.removeFirst() }
            if position % 3200 == 0 {
                let floor = noise.sorted()[noise.count / 10]
                threshold = max(0.006, min(0.008, floor) * 2.5)
            }
            if rms > threshold {
                if phrase.isEmpty {
                    start = position - preRoll.count
                    phrase = preRoll
                    preRoll.removeAll(keepingCapacity: true)
                    id = UUID()
                    revision = 0
                    emittedFrames = 0
                }
                lastVoice = position + 320
                voicedFrames += 320
            }
            if !phrase.isEmpty {
                phrase += block
                if (phrase.count >= 192_000 && position + 320 - lastVoice >= 19_200) || phrase.count >= 448_000 {
                    if let item = finish() { output.append(item) }
                } else if phrase.count - emittedFrames >= 48_000, voicedFrames >= 2880 {
                    output.append(snapshot(final: false))
                }
            } else {
                preRoll += block
                if preRoll.count > 3200 { preRoll.removeFirst(preRoll.count - 3200) }
            }
            position += 320
        }
        tail.removeFirst(offset)
        return output
    }

    mutating func flush() -> AudioPhrase? {
        if !phrase.isEmpty { phrase += tail }
        tail.removeAll()
        return finish()
    }

    private mutating func snapshot(final: Bool) -> AudioPhrase {
        revision += 1
        emittedFrames = phrase.count
        return AudioPhrase(id: id, revision: revision, isFinal: final, samples: phrase,
                           start: Double(start) / 16_000, end: Double(lastVoice) / 16_000)
    }

    private mutating func finish() -> AudioPhrase? {
        defer { phrase.removeAll(keepingCapacity: true); voicedFrames = 0 }
        guard voicedFrames >= 2880 else { return nil }
        return snapshot(final: true)
    }
}

// Mutable inference state is confined to queue; queued work retains the instance.
final class LocalWhisper: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.live-translate.whisper", qos: .userInitiated)
    private var context: UnsafeMutableRawPointer?
    private var vadPath = ""

    func unload() async {
        await withCheckedContinuation { continuation in
            queue.async {
                lt_whisper_close(self.context)
                self.context = nil
                self.vadPath = ""
                continuation.resume()
            }
        }
    }

    func prepare(model: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.vadPath = model.deletingLastPathComponent().appendingPathComponent("ggml-silero-v6.2.0.bin").path
                guard FileManager.default.fileExists(atPath: self.vadPath) else {
                    continuation.resume(throwing: NSError(domain: "Whisper", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "缺少本地人声检测模型，请在 App 中重新下载模型。"]))
                    return
                }
                if self.context == nil { self.context = lt_whisper_open(model.path) }
                if self.context != nil { continuation.resume() }
                else { continuation.resume(throwing: NSError(domain: "Whisper", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "无法加载 Whisper 模型，请检查模型下载状态后重试。"])) }
            }
        }
    }

    func transcribe(_ samples: [Float], context prompt: String = "") async throws -> String {
        // Digital silence must not enter a generative decoder: no-speech scores
        // alone do not reliably suppress hallucinations with large-v3-turbo.
        guard samples.contains(where: { abs($0) > 0.00001 }) else { return "" }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let context = self.context else {
                    continuation.resume(throwing: TranslationError.server)
                    return
                }
                // Whisper expects at least a second of audio for short utterances.
                let padded = samples.count < 16_000 ? samples + Array(repeating: Float(0), count: 16_000 - samples.count) : samples
                var status: Int32 = 0
                let result = padded.withUnsafeBufferPointer {
                    lt_whisper_transcribe(context, $0.baseAddress, Int32($0.count), prompt, self.vadPath, &status)
                }
                if status == -100 { continuation.resume(throwing: RecognitionError.unreliable); return }
                guard let result else {
                    continuation.resume(throwing: NSError(domain: "Whisper", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "本地语音识别失败，原始录音仍已保存。"]))
                    return
                }
                let text = String(cString: result).trimmingCharacters(in: .whitespacesAndNewlines)
                lt_whisper_free_text(result)
                continuation.resume(returning: text)
            }
        }
    }

    deinit { lt_whisper_close(context) }
}
