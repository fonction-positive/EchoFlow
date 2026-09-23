import Foundation
@preconcurrency import AVFoundation

// Local-only regression replay. No microphone, network, or original-file writes.
enum RecognitionReplay {
    static func run(file: URL, start: Double, end: Double) async throws {
        let input = try AVAudioFile(forReading: file)
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: input.processingFormat, to: mono)!
        let engine = LocalWhisper()
        try await engine.prepare(model: URL(fileURLWithPath: "models/ggml-large-v3-turbo.bin"))
        var segmenter = AudioSegmenter()
        var history: [Caption] = []
        var checked = 0, rejected = 0, empty = 0
        while input.framePosition < input.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.processingFormat.sampleRate))!
            try input.read(into: buffer)
            let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 16032)!
            var sent = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if sent { status.pointee = .noDataNow; return nil }
                sent = true; status.pointee = .haveData; return buffer
            }
            if let error { throw error }
            let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            for phrase in segmenter.append(samples) where phrase.isFinal && phrase.start >= start && phrase.start <= end {
                let prompt = RecognitionText.context(from: history, excluding: phrase.id)
                let began = Date()
                var row = Caption(id: phrase.id, start: phrase.start, end: phrase.end, english: "")
                do {
                    let text = try await engine.transcribe(phrase.samples, context: prompt)
                    precondition(!lt_repetition_candidate(text), "A looping result reached the caller")
                    row.recognize(phrase, english: text)
                    if text.isEmpty { empty += 1 }
                    print("REPLAY \(phrase.start) prompt=\(prompt.count) seconds=\(Date().timeIntervalSince(began)) text=\(text)")
                } catch RecognitionError.unreliable {
                    row.recognize(phrase, english: "")
                    rejected += 1
                    print("REPLAY \(phrase.start) rejected unreliable candidate")
                }
                history.append(row)
                checked += 1
                fflush(stdout)
            }
            if Double(input.framePosition) / input.processingFormat.sampleRate > end + 30 { break }
        }
        precondition(checked > 0, "No matching windows")
        print("REPLAY SUMMARY windows=\(checked) rejected=\(rejected) noSpeech=\(empty)")
    }
}
