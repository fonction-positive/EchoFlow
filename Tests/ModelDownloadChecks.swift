import Foundation
import CryptoKit

@MainActor
enum ModelDownloadChecks {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
        if !condition() { fputs("FAIL ModelDownloadChecks:\(line): \(message)\n", stderr); exit(1) }
    }
    static func storage() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        let data = Data("model contents".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = RecognitionModelFile(name: "test.bin", url: URL(string: "https://example.invalid/model")!, size: Int64(data.count), sha256: hash)
        try data.write(to: source.appendingPathComponent(file.name))
        let recording = source.appendingPathComponent("recording.wav")
        try Data("user recording".utf8).write(to: recording)
        let suite = "EchoFlowStorageTests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(source.path, forKey: "recognitionModelDirectory")
        let models = ModelDownloads(files: [file], preferences: preferences)
        await models.inspect()
        expect(models.ready && models.occupiedBytes == data.count)
        await models.move(to: target)
        expect(models.ready && models.directory.path == target.path && models.modelURL != nil, models.message)
        expect(!manager.fileExists(atPath: source.appendingPathComponent(file.name).path))
        expect(manager.fileExists(atPath: recording.path), "Migration must preserve recordings")
        let reopened = ModelDownloads(files: [file], preferences: preferences)
        await reopened.inspect()
        expect(reopened.directory.path == target.path && reopened.ready, "Custom path must survive restart")
        await models.move(to: URL(fileURLWithPath: target.path, isDirectory: true))
        expect(models.ready, "Same directory must be a no-op")
        let conflict = root.appendingPathComponent("conflict")
        try manager.createDirectory(at: conflict, withIntermediateDirectories: true)
        let conflictFile = conflict.appendingPathComponent(file.name)
        try Data("unrelated".utf8).write(to: conflictFile)
        await models.move(to: conflict)
        expect(models.directory.path == target.path && models.ready && models.message.contains("失败"))
        let unchanged = try Data(contentsOf: conflictFile)
        expect(unchanged == Data("unrelated".utf8))
        expect(preferences.string(forKey: "recognitionModelDirectory") == target.path)
        // A later validation failure must roll back earlier copies and preserve all originals.
        let invalid = RecognitionModelFile(name: "bad.bin", url: file.url, size: file.size, sha256: hash)
        try Data("bad".utf8).write(to: target.appendingPathComponent(invalid.name))
        let broken = ModelDownloads(directory: target, files: [file, invalid])
        await broken.inspect()
        let rollback = root.appendingPathComponent("rollback")
        await broken.move(to: rollback)
        expect(broken.directory.path == target.path && broken.message.contains("失败"))
        let originalValid = try file.validate(target.appendingPathComponent(file.name))
        expect(originalValid)
        let leftovers = try manager.contentsOfDirectory(atPath: rollback.path)
        expect(leftovers.isEmpty)
        await models.remove()
        expect(!models.ready && models.occupiedBytes == 0 && models.modelURL == nil)
        expect(manager.fileExists(atPath: target.appendingPathComponent(invalid.name).path), "Remove only catalogued models")
        expect(manager.fileExists(atPath: recording.path))
        print("PASS: model migration, persisted path, conflict protection, rollback, removal and unrelated files")
    }

    static func officialSmoke() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RecognitionModelFile.required.last!
        let downloads = ModelDownloads(directory: root, files: [model])
        await downloads.inspect(); downloads.start(); await downloads.waitForDownload()
        expect(downloads.ready, downloads.message)
        print("PASS: official VAD model downloaded through app code and verified by SHA-256")
    }
    static func run(server: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 69, count: 262_144)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func model(_ path: String, hash: String) -> RecognitionModelFile {
            .init(name: "test-model.bin", url: server.appendingPathComponent(path), size: Int64(data.count), sha256: hash)
        }
        let valid = model("good", hash: hash)
        let downloads = ModelDownloads(directory: root.appendingPathComponent("good"), files: [valid])
        await downloads.inspect()
        expect(!downloads.ready && !downloads.checking)
        downloads.start()
        await downloads.waitForDownload()
        expect(downloads.ready && downloads.progress == 1, downloads.message)
        let reopened = ModelDownloads(directory: downloads.directory, files: [valid])
        await reopened.inspect()
        expect(reopened.ready, "Validated models survive app upgrades/restarts")
        try Data(repeating: 0, count: data.count).write(to: downloads.modelURL!)
        let corrupted = ModelDownloads(directory: downloads.directory, files: [valid])
        await corrupted.inspect()
        expect(!corrupted.ready, "A same-size corrupt file must fail SHA-256")
        corrupted.start()
        await corrupted.waitForDownload()
        expect(corrupted.ready, corrupted.message)

        let bad = ModelDownloads(directory: root.appendingPathComponent("bad"), files: [model("good", hash: String(repeating: "0", count: 64))])
        await bad.inspect(); bad.start(); await bad.waitForDownload()
        expect(!bad.ready && bad.message.contains("校验失败"))
        expect(!FileManager.default.fileExists(atPath: bad.directory.appendingPathComponent("test-model.bin").path))
        let http = ModelDownloads(directory: root.appendingPathComponent("http"), files: [model("error", hash: hash)])
        await http.inspect(); http.start(); await http.waitForDownload()
        expect(!http.ready && http.message.contains("失败"))
        let slow = ModelDownloads(directory: root.appendingPathComponent("slow"), files: [model("slow", hash: hash)])
        await slow.inspect(); slow.start()
        for _ in 0..<60 {
            if slow.progress > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        expect(slow.downloading && slow.progress > 0 && slow.progress < 1,
               "Download must report intermediate progress: running=\(slow.downloading), progress=\(slow.progress), \(slow.message)")
        slow.cancel(); await slow.waitForDownload()
        expect(!slow.ready && slow.message.contains("取消"))
        expect(!FileManager.default.fileExists(atPath: slow.directory.appendingPathComponent("test-model.bin").path))
        slow.start(); await slow.waitForDownload()
        expect(slow.ready, "Retry after cancellation must work: \(slow.message)")
        print("PASS: model download, progress, SHA-256 rejection, HTTP failure, cancellation, retry and model reuse")
    }
}
