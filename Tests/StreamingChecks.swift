import Foundation

@MainActor
enum StreamingChecks {
    static func run() async throws {
        var first = Caption(start: 0, end: 3, english: "A quoted value")
        first.rawEnglish = first.english
        first.revision = 1
        var second = Caption(start: 3, end: 6, english: "Second sentence")
        second.rawEnglish = second.english
        second.revision = 2
        let a = CaptionCorrection(id: first.id, revision: 1, english: #"A "quoted" {value} \ path"#,
                                  chinese: "引号与括号：{值}。", uncertain: false)
        let b = CaptionCorrection(id: second.id, revision: 2, english: second.english, chinese: "第二句。", uncertain: false)
        let encode = { (row: CaptionCorrection) throws in String(decoding: try JSONEncoder().encode(row), as: UTF8.self) }
        let aJSON = try encode(a), bJSON = try encode(b)
        var stream = CorrectionStream(targets: [first, second])
        let early = try stream.append("{\"rows\":[" + aJSON + ",")
        precondition(early.count == 1 && early[0].chinese == a.chinese, "First row must be delivered before the rest of the batch")
        var late: [CaptionCorrection] = []
        for character in bJSON { late += try stream.append(String(character)) }
        precondition(late.count == 1 && late[0].chinese == b.chinese)
        _ = try stream.append("]}")
        let complete = try stream.finish()
        precondition(complete.count == 2)
        precondition(first.apply(a, complete: false) && first.status == "pending")
        precondition(first.apply(a) && first.status == "done")
        first.revision = 9
        precondition(!first.apply(a, complete: false), "A late streamed row must not overwrite new recognition")
        first.revision = 1

        for invalid in ["{\"rows\":[" + aJSON + "," + aJSON + "]}",
                        "{\"rows\":[" + aJSON,
                        "{\"rows\":[" + aJSON + "," + bJSON + ",]}"] {
            do {
                var broken = CorrectionStream(targets: [first, second])
                _ = try broken.append(invalid)
                _ = try broken.finish()
                fatalError("Duplicate/truncated/malformed responses must fail")
            } catch {}
        }
        let stale = CaptionCorrection(id: second.id, revision: 1, english: "Old", chinese: "旧版", uncertain: false)
        do {
            var broken = CorrectionStream(targets: [second])
            _ = try broken.append("{\"rows\":[" + encode(stale) + "]}")
            fatalError("Stale streamed row must fail validation")
        } catch {}

        let key = try DeepSeek.input(targets: [first, second], history: [], includeRevisions: false)
        var cache = CorrectionCache()
        cache.insert([a, b], for: key)
        first.revision = 10
        let same = try DeepSeek.input(targets: [first, second], history: [], includeRevisions: false)
        precondition(same == key)
        precondition(cache.response(for: same, targets: [first, second])?.first?.revision == 10)
        for changedKey in [
            try DeepSeek.input(targets: [first, second], history: [second], includeRevisions: false),
            try DeepSeek.input(targets: [first], history: [], includeRevisions: false)
        ] { precondition(cache.response(for: changedKey, targets: [first, second]) == nil) }
        second.rawEnglish = "Changed source"
        let changed = try DeepSeek.input(targets: [first, second], history: [], includeRevisions: false)
        precondition(cache.response(for: changed, targets: [first, second]) == nil)
        second.isFinal = true
        let finalInput = try DeepSeek.input(targets: [first, second], history: [], includeRevisions: false)
        precondition(finalInput != changed)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(parent: root)
        for revision in 1...100 {
            first.revision = revision
            first.chinese = "Revision \(revision)"
            store.enqueue(first) { result in
                precondition(!Thread.isMainThread, "Disk work must not complete on the UI thread")
                if case .failure(let error) = result { fatalError(error.localizedDescription) }
            }
        }
        store.flush()
        let journal = try String(contentsOf: store.directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        let exported = try String(contentsOf: store.directory.appendingPathComponent("chinese.txt"), encoding: .utf8)
        precondition(journal.split(separator: "\n").count == 100)
        precondition(store.captions.count == 1 && store.captions[0].revision == 100 && exported.contains("Revision 100"))
        print("PASS: early complete rows, split/escaped JSON, stale and malformed responses, context-aware cache, ordered background persistence and flush")
    }

    static func liveSmoke() async throws {
        // Only synthetic test sentences are sent; no saved recordings are read.
        let key = try String(contentsOfFile: "api.env", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = DeepSeek(key: key)
        var targets = ["The result is 128 bytes.", "Each thread reads a different element.", "The next example uses 256 bytes."].enumerated().map { index, text in
            var row = Caption(start: Double(index * 3), end: Double(index * 3 + 3), english: text)
            row.rawEnglish = text; row.revision = 1; row.isFinal = true
            return row
        }
        let began = Date()
        var arrivals: [Double] = []
        let rows = try await client.revise(targets: targets, history: []) { _ in arrivals.append(Date().timeIntervalSince(began)) }
        let full = Date().timeIntervalSince(began)
        precondition(rows.count == 3 && arrivals.count == 3)
        for index in targets.indices { targets[index].revision += 1 }
        let cached = try await client.revise(targets: targets, history: [])
        precondition(cached.allSatisfy { $0.revision == 2 })
        print("PASS: official API synthetic streaming rows at \(arrivals), batch completed at \(full)s; cache remaps revisions")
    }
}
