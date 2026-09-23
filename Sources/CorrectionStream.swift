import Foundation

// Decode complete row objects as they arrive, keeping JSON strings/escapes intact.
// Rows are provisional until the whole response has passed final validation.
struct CorrectionStream {
    private let targets: [Caption]
    private var bytes: [UInt8] = []
    private var cursor = 0
    private var started = false
    private var objectStart: Int?
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var seen = Set<UUID>()
    private var afterRow = false
    private var needsRow = false
    private var closedArray = false
    private var ended = false

    init(targets: [Caption]) { self.targets = targets }

    mutating func append(_ fragment: String) throws -> [CaptionCorrection] {
        bytes.append(contentsOf: fragment.utf8)
        var rows: [CaptionCorrection] = []
        while cursor < bytes.count {
            let byte = bytes[cursor]
            defer { cursor += 1 }
            if !started {
                if byte == 91 { // [ after the envelope's rows key
                    let prefix = String(decoding: bytes[...cursor], as: UTF8.self)
                    guard prefix.range(of: #"^\s*\{\s*"rows"\s*:\s*\[$"#, options: .regularExpression) != nil else {
                        throw TranslationError.incomplete
                    }
                    started = true
                }
                continue
            }
            if objectStart == nil {
                if [UInt8(9), 10, 13, 32].contains(byte) { continue }
                guard !ended else { throw TranslationError.incomplete }
                if closedArray {
                    guard byte == 125 else { throw TranslationError.incomplete }
                    ended = true
                } else if byte == 123 && !afterRow { objectStart = cursor; depth = 1 }
                else if byte == 44 && afterRow { afterRow = false; needsRow = true }
                else if byte == 93 && !needsRow { closedArray = true }
                else { throw TranslationError.incomplete }
                continue
            }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0, let start = objectStart {
                    let row = try JSONDecoder().decode(CaptionCorrection.self, from: Data(bytes[start...cursor]))
                    guard targets.contains(where: { $0.id == row.id && $0.revision == row.revision }),
                          seen.insert(row.id).inserted,
                          !row.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !row.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TranslationError.incomplete
                    }
                    rows.append(row)
                    objectStart = nil
                    afterRow = true
                    needsRow = false
                }
            }
        }
        return rows
    }

    func finish() throws -> [CaptionCorrection] {
        guard ended else { throw TranslationError.incomplete }
        return try CorrectionResponse.parse(String(decoding: bytes, as: UTF8.self), targets: targets)
    }
}

struct CorrectionCache {
    private var values: [Data: [CaptionCorrection]] = [:]
    private var order: [Data] = []

    func response(for key: Data, targets: [Caption]) -> [CaptionCorrection]? {
        guard let rows = values[key], rows.count == targets.count else { return nil }
        let revisions = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.revision) })
        guard rows.allSatisfy({ revisions[$0.id] != nil }) else { return nil }
        return rows.map { CaptionCorrection(id: $0.id, revision: revisions[$0.id]!,
            english: $0.english, chinese: $0.chinese, uncertain: $0.uncertain) }
    }

    mutating func insert(_ rows: [CaptionCorrection], for key: Data) {
        if values[key] == nil { order.append(key) }
        values[key] = rows
        if order.count > 32 { values.removeValue(forKey: order.removeFirst()) }
    }
}
