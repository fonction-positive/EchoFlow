import AVFoundation

struct AudioRecoveryState: Codable {
    let sampleRate: Double
    let channels: Int
    var frames: Int64
}

// Audio files, resampling and segmentation run on this serial queue.
// Model inference is separate and cannot block microphone recording.
final class AudioCapture {
    private static let recoveryAudioName = "recording-recovery.pcm"
    private static let recoveryStateName = "recording-recovery.json"
    private static let finalAudioName = "audio.wav"
    private static let checkpointInterval = 5.0

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "local.live-translate.audio")
    private var converter: AVAudioConverter?
    private var archiveConverter: AVAudioConverter?
    private let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var archiveFormat: AVAudioFormat?
    private var recoveryFile: FileHandle?
    private var segmenter = AudioSegmenter()
    private var directory: URL?
    private var totalFrames: AVAudioFramePosition = 0
    private var active = false
    private var sampleRate = 1.0
    private var lastCheckpoint = ProcessInfo.processInfo.systemUptime
    var onError: ((String) -> Void)?
    var onPhrase: ((AudioPhrase) -> Void)?

    var duration: Double { queue.sync { Double(totalFrames) / sampleRate } }

    func start(directory: URL) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风"])
        }
        try queue.sync {
            self.directory = directory
            sampleRate = format.sampleRate
            totalFrames = 0
            segmenter = AudioSegmenter()
            converter = AVAudioConverter(from: format, to: mono)
            archiveFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate,
                                          channels: format.channelCount, interleaved: true)
            guard converter != nil, let archiveFormat else { throw CocoaError(.coderInvalidValue) }
            archiveConverter = AVAudioConverter(from: format, to: archiveFormat)
            guard archiveConverter != nil else { throw CocoaError(.coderInvalidValue) }
            try openRecoveryFile(format: archiveFormat)
            active = true
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (src, dst) in zip(source, target) {
                if let s = src.mData, let d = dst.mData { memcpy(d, s, Int(src.mDataByteSize)) }
            }
            self.queue.async {
                guard self.active else { return }
                do {
                    try self.archive(copy)
                    self.totalFrames += AVAudioFramePosition(copy.frameLength)
                    try self.process(copy)
                    if ProcessInfo.processInfo.systemUptime - self.lastCheckpoint >= Self.checkpointInterval {
                        try self.checkpoint()
                    }
                } catch {
                    self.active = false
                    try? self.recoveryFile?.synchronize()
                    try? self.recoveryFile?.close()
                    self.recoveryFile = nil
                    DispatchQueue.main.async { self.onError?("录音保存失败：\(error.localizedDescription)") }
                }
            }
        }
        do { try engine.start() }
        catch { stop(); throw error }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.sync {
            active = false
            if let last = segmenter.flush() { onPhrase?(last) }
            do {
                try checkpoint()
                try recoveryFile?.close()
                recoveryFile = nil
                try Self.finalizeRecovery(in: directory)
            } catch {
                DispatchQueue.main.async { self.onError?("录音已保留为可恢复原始文件：\(error.localizedDescription)") }
            }
            converter = nil
            archiveConverter = nil
            archiveFormat = nil
        }
    }

    func pause() throws {
        engine.pause()
        try queue.sync {
            guard active else { return }
            try checkpoint()
        }
    }

    func resume() throws {
        try engine.start()
    }

    static func recoverIncompleteSessions(in parent: URL) throws -> Int {
        let children = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])
        var recovered = 0
        for directory in children {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let raw = directory.appendingPathComponent(recoveryAudioName)
            let state = directory.appendingPathComponent(recoveryStateName)
            guard FileManager.default.fileExists(atPath: raw.path), FileManager.default.fileExists(atPath: state.path) else { continue }
            let final = directory.appendingPathComponent(finalAudioName)
            if FileManager.default.fileExists(atPath: final.path) {
                try FileManager.default.removeItem(at: raw)
                try FileManager.default.removeItem(at: state)
            } else {
                try finalizeRecovery(in: directory)
                recovered += 1
            }
        }
        return recovered
    }

    private func archive(_ buffer: AVAudioPCMBuffer) throws {
        guard let archiveFormat else { throw CocoaError(.fileNoSuchFile) }
        let output = AVAudioPCMBuffer(pcmFormat: archiveFormat, frameCapacity: buffer.frameLength + 32)!
        var sent = false
        var error: NSError?
        archiveConverter?.convert(to: output, error: &error) { _, status in
            if sent { status.pointee = .noDataNow; return nil }
            sent = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let bytes = output.audioBufferList.pointee.mBuffers.mData else { throw CocoaError(.fileWriteUnknown) }
        let count = Int(output.audioBufferList.pointee.mBuffers.mDataByteSize)
        try recoveryFile?.write(contentsOf: Data(bytes: bytes, count: count))
    }

    private func process(_ buffer: AVAudioPCMBuffer) throws {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / sampleRate)) + 32
        let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity)!
        var sent = false
        var error: NSError?
        converter?.convert(to: output, error: &error) { _, status in
            if sent { status.pointee = .noDataNow; return nil }
            sent = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        for phrase in segmenter.append(samples) { onPhrase?(phrase) }
    }

    private func openRecoveryFile(format: AVAudioFormat) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let raw = directory.appendingPathComponent(Self.recoveryAudioName)
        guard FileManager.default.createFile(atPath: raw.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        recoveryFile = try FileHandle(forWritingTo: raw)
        lastCheckpoint = ProcessInfo.processInfo.systemUptime
        try Self.writeRecoveryState(AudioRecoveryState(sampleRate: format.sampleRate, channels: Int(format.channelCount), frames: 0), in: directory)
    }

    private func checkpoint() throws {
        guard let directory, let archiveFormat else { return }
        try recoveryFile?.synchronize()
        try Self.writeRecoveryState(AudioRecoveryState(sampleRate: archiveFormat.sampleRate,
                                                       channels: Int(archiveFormat.channelCount), frames: Int64(totalFrames)), in: directory)
        lastCheckpoint = ProcessInfo.processInfo.systemUptime
    }

    private static func writeRecoveryState(_ state: AudioRecoveryState, in directory: URL) throws {
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent(recoveryStateName), options: .atomic)
    }

    private static func finalizeRecovery(in directory: URL?) throws {
        guard let directory else { return }
        let raw = directory.appendingPathComponent(recoveryAudioName)
        let stateURL = directory.appendingPathComponent(recoveryStateName)
        let state = try JSONDecoder().decode(AudioRecoveryState.self, from: Data(contentsOf: stateURL))
        let byteCount = try raw.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let usableBytes = min(byteCount, Int(state.frames) * state.channels * 2)
        let partial = directory.appendingPathComponent("audio.wav.partial")
        let final = directory.appendingPathComponent(finalAudioName)
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: wavHeader(dataSize: usableBytes, state: state)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: raw)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? input.close(); try? output.close() }
        try output.seekToEnd()
        var remaining = usableBytes
        while remaining > 0 {
            let data = try input.read(upToCount: min(1_048_576, remaining)) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            remaining -= data.count
        }
        try output.synchronize()
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: partial, to: final)
        try FileManager.default.removeItem(at: raw)
        try FileManager.default.removeItem(at: stateURL)
    }

    private static func wavHeader(dataSize: Int, state: AudioRecoveryState) -> Data {
        let channels = UInt16(state.channels)
        let sampleRate = UInt32(state.sampleRate.rounded())
        var data = Data("RIFF".utf8)
        data.appendLE(UInt32(36 + dataSize))
        data.append(Data("WAVEfmt ".utf8))
        data.appendLE(UInt32(16)); data.appendLE(UInt16(1)); data.appendLE(channels); data.appendLE(sampleRate)
        data.appendLE(sampleRate * UInt32(channels) * 2); data.appendLE(channels * 2); data.appendLE(UInt16(16))
        data.append(Data("data".utf8)); data.appendLE(UInt32(dataSize))
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
