import Foundation

struct RecordingMetadata: Codable {
    var title: String
    var createdAt: Date
    var endedAt: Date?
    var duration: Double?

    static func defaultTitle(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct RecordingEntry: Identifiable {
    var id: String { directory.path }
    let directory: URL
    let title: String
    let createdAt: Date
}

enum RecordLibrary {
    static func list(in root: URL) throws -> [RecordingEntry] {
        let manager = FileManager.default
        return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles])
            .compactMap { directory in
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
                guard values.isDirectory == true,
                      manager.fileExists(atPath: directory.appendingPathComponent("events.jsonl").path) else { return nil }
                let metadata = try? JSONDecoder().decode(RecordingMetadata.self,
                    from: Data(contentsOf: directory.appendingPathComponent("session.json")))
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let legacyDate = directory.lastPathComponent.hasPrefix("LiveTranslate_")
                    ? formatter.date(from: String(directory.lastPathComponent.dropFirst(14).prefix(19))) : nil
                return RecordingEntry(directory: directory,
                    title: metadata?.title ?? directory.lastPathComponent,
                    createdAt: metadata?.createdAt ?? legacyDate ?? values.creationDate ?? .distantPast)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func captions(in directory: URL) throws -> [Caption] {
        let journal = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        var latest: [UUID: Caption] = [:]
        for line in journal.split(separator: "\n") {
            // A crash may leave a partial final line; earlier complete revisions remain usable.
            if let row = try? JSONDecoder().decode(Caption.self, from: Data(line.utf8)) { latest[row.id] = row }
        }
        return latest.values.sorted { $0.start < $1.start }
    }
}

// The first released app did not yet have revision or rawEnglish fields.
extension Caption {
    enum CodingKeys: String, CodingKey {
        case id, start, end, english, chinese, status, firstTokenLatency, rawEnglish, revision, isFinal, uncertain
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        english = try values.decode(String.self, forKey: .english)
        chinese = try values.decodeIfPresent(String.self, forKey: .chinese) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "done"
        firstTokenLatency = try values.decodeIfPresent(Double.self, forKey: .firstTokenLatency)
        rawEnglish = try values.decodeIfPresent(String.self, forKey: .rawEnglish) ?? english
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        isFinal = try values.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
        uncertain = try values.decodeIfPresent(Bool.self, forKey: .uncertain) ?? false
    }
}
