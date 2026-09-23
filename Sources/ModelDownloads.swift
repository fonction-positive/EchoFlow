import Foundation
import Combine
import CryptoKit

struct RecognitionModelFile: Sendable {
    let name: String
    let url: URL
    let size: Int64
    let sha256: String

    static let required: [RecognitionModelFile] = [
        .init(name: "ggml-large-v3-turbo.bin",
              url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
              size: 1_624_555_275, sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        .init(name: "ggml-silero-v6.2.0.bin",
              url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!,
              size: 885_098, sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987")
    ]

    func validate(_ file: URL) throws -> Bool {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true, values?.fileSize == Int(size) else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }
}

private final class ModelDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let update: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var temporary: URL?
    private var fileError: Error?
    private var cancelled = false
    private var lastUpdate = 0.0 // Accessed only on the serial delegate queue.

    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }

    func download(_ url: URL, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                downloadTask = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.downloadTask
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUpdate >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastUpdate = now
        update(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system removes location after this callback; take ownership now.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("echoflow-model-\(UUID().uuidString).download")
        do {
            try FileManager.default.moveItem(at: location, to: owned)
            lock.lock(); temporary = owned; lock.unlock()
        } catch { lock.lock(); fileError = error; lock.unlock() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation, temporary = temporary
        let failure: Error? = cancelled ? CancellationError() : (error ?? fileError)
        self.continuation = nil
        self.downloadTask = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let failure {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            continuation?.resume(throwing: failure)
        } else if let temporary, let response = task.response {
            continuation?.resume(returning: (temporary, response))
        } else {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }
}

@MainActor
final class ModelDownloads: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var checking = true
    @Published private(set) var downloading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var message = "正在检查本地识别模型…"
    @Published private(set) var directory: URL
    @Published private(set) var managing = false
    @Published private(set) var occupiedBytes: Int64 = 0
    private let preferences: UserDefaults?
    private let files: [RecognitionModelFile]
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var inspected = false
    private var attempt = UUID()

    var busy: Bool { checking || downloading || managing }
    var occupiedSize: String { occupiedBytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: occupiedBytes, countStyle: .file) }
    var modelURL: URL? { ready && !busy ? directory.appendingPathComponent(files[0].name) : nil }
    var totalSize: String { ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file) }

    init(directory: URL? = nil, files: [RecognitionModelFile] = RecognitionModelFile.required, session: URLSession = .shared,
         preferences: UserDefaults = .standard) {
        self.preferences = directory == nil ? preferences : nil
        let saved = preferences.string(forKey: "recognitionModelDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.directory = directory ?? saved ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoFlow/Models", isDirectory: true)
        self.files = files
        self.session = session
    }

    func inspect() async {
        guard !inspected else { return }
        inspected = true
        let files = files, directory = directory
        ready = (try? await Task.detached(priority: .utility) {
            for file in files where try !file.validate(directory.appendingPathComponent(file.name)) { return false }
            return true
        }.value) ?? false
        refreshSize()
        checking = false
        message = ready ? "识别模型已就绪，离线运行。" : "首次使用需下载 \(totalSize) 模型，之后无需重复下载。"
    }

    func start() {
        guard !busy, !ready else { return }
        downloading = true
        progress = 0
        attempt = UUID()
        let thisAttempt = attempt
        task = Task {
            defer { downloading = false; task = nil; refreshSize() }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let total = Double(files.reduce(0) { $0 + $1.size })
                var completed: Int64 = 0
                for file in files {
                    try Task.checkCancellation()
                    let destination = directory.appendingPathComponent(file.name)
                    if try await Task.detached(priority: .utility, operation: { try file.validate(destination) }).value {
                        completed += file.size
                        progress = Double(completed) / total
                        continue
                    }
                    message = "正在下载 \(file.name)…"
                    let base = completed
                    let transfer = ModelDownloadTransfer { [weak self] written in
                        Task { @MainActor in
                            guard let self, self.attempt == thisAttempt, self.downloading else { return }
                            self.progress = max(self.progress, min(1, Double(base + written) / total))
                        }
                    }
                    let configuration = session.configuration
                    configuration.urlCache = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    let (temporary, response) = try await transfer.download(file.url, configuration: configuration)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw NSError(domain: "ModelDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "模型服务器响应异常，请重试。"])
                    }
                    message = "正在校验 \(file.name)…"
                    let valid = try await Task.detached(priority: .utility) { try file.validate(temporary) }.value
                    try Task.checkCancellation()
                    guard valid else {
                        throw NSError(domain: "ModelDownload", code: 2, userInfo: [NSLocalizedDescriptionKey: "模型校验失败，请重试下载。"])
                    }
                    // The old file (if corrupt) is replaced only after the new one passes validation.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                    } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                    completed += file.size
                    progress = Double(completed) / total
                }
                ready = true
                message = "识别模型已就绪，离线运行。"
            } catch {
                message = Task.isCancelled ? "下载已取消，可重新下载；已完成的模型会保留。" : "下载失败：\(error.localizedDescription)"
            }
        }
    }

    private func refreshSize() {
        occupiedBytes = files.reduce(0) { total, file in
            total + Int64((try? directory.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func move(to target: URL) async {
        guard !busy else { return }
        let target = target.standardizedFileURL.resolvingSymlinksInPath()
        let source = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard source.path != target.path else { return }
        managing = true
        message = "正在迁移并校验模型…"
        let files = files
        task = Task {
            defer { managing = false; task = nil; refreshSize() }
            do {
                try await Task.detached(priority: .utility) {
                    try Self.copyModels(files, from: source, to: target)
                }.value
                // Commit the new location before removing any source file.
                directory = target
                preferences?.set(target.path, forKey: "recognitionModelDirectory")
                let cleanupError = await Task.detached(priority: .utility) { () -> String? in
                    do { try Self.removeModels(files, from: source); return nil }
                    catch { return error.localizedDescription }
                }.value
                inspected = false
                checking = true
                await inspect()
                if let cleanupError { message = "模型已迁移，旧目录清理失败：\(source.path)（\(cleanupError)）" }
            } catch { message = "迁移失败，原目录保持不变：\(error.localizedDescription)" }
        }
        await task?.value
    }

    func remove() async {
        guard !busy else { return }
        managing = true
        ready = false
        let files = files, directory = directory
        task = Task {
            defer { managing = false; task = nil; refreshSize() }
            do {
                try await Task.detached(priority: .utility) { try Self.removeModels(files, from: directory) }.value
                message = "识别模型已移除。需要使用时可重新下载。"
            } catch { message = "移除失败：\(error.localizedDescription)" }
        }
        await task?.value
    }

    nonisolated private static func copyModels(_ files: [RecognitionModelFile], from source: URL, to target: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        var created: [URL] = []
        do {
            for file in files {
                let old = source.appendingPathComponent(file.name), new = target.appendingPathComponent(file.name)
                if manager.fileExists(atPath: new.path) {
                    guard try file.validate(new) else {
                        throw NSError(domain: "ModelStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "目标目录存在同名但无效的文件：\(file.name)。请选择其他目录。"])
                    }
                    continue
                }
                guard manager.fileExists(atPath: old.path) else { continue }
                let temporary = target.appendingPathComponent(".echoflow-\(UUID().uuidString).tmp")
                defer { try? manager.removeItem(at: temporary) }
                try manager.copyItem(at: old, to: temporary)
                guard try file.validate(temporary) else {
                    throw NSError(domain: "ModelStorage", code: 2, userInfo: [NSLocalizedDescriptionKey: "模型校验失败，原文件已保留：\(file.name)。请重新下载。"])
                }
                try manager.moveItem(at: temporary, to: new)
                created.append(new)
            }
        } catch {
            for file in created { try? manager.removeItem(at: file) }
            throw error
        }
    }

    nonisolated private static func removeModels(_ files: [RecognitionModelFile], from directory: URL) throws {
        for file in files {
            let url = directory.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true || values.isSymbolicLink == true else {
                    throw NSError(domain: "ModelStorage", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法移除非模型文件：\(url.path)"])
                }
                try FileManager.default.removeItem(at: url)
            }
        }
        // Keep the directory and any unrelated user files.
    }

    func cancel() { if downloading { task?.cancel() } }

    // Used for shutdown and deterministic download tests.
    func waitForDownload() async { await task?.value }
}
