import Foundation

enum RecognitionText {
    static func context(from rows: [Caption], excluding id: UUID) -> String {
        // Reject an entire contaminated source, rather than turning its loop into a prompt.
        let recent = rows.filter { $0.id != id && $0.isFinal }.suffix(2)
        return String(recent.map(\.rawEnglish)
            .filter { !$0.isEmpty && !lt_repetition_candidate($0) }
            .joined(separator: " ").suffix(800))
    }

    // Only collapse long consecutive loops, not ordinary emphasis or recurring terms.
    // Callers keep the original ASR output separately for diagnosis.
    static func removingLoops(_ text: String) -> String {
        let source = text as NSString
        let matches = try! NSRegularExpression(pattern: "\\S+")
            .matches(in: text, range: NSRange(location: 0, length: source.length))
        guard matches.count >= 24 else { return text }
        let words = matches.map { source.substring(with: $0.range).lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var removals: [NSRange] = []
        var start = 0
        while start + 24 <= words.count {
            var loopEnd: Int?
            for width in 1...min(64, (words.count - start) / 4) {
                let unit = words[start..<(start + width)]
                guard unit.contains(where: { !$0.isEmpty }) else { continue }
                var end = start + width
                while end + width <= words.count,
                      words[end..<(end + width)].elementsEqual(unit) { end += width }
                guard (end - start) / width >= 4, end - start >= 24 else { continue }
                let keepEnd = NSMaxRange(matches[start + width - 1].range)
                removals.append(NSRange(location: keepEnd, length: NSMaxRange(matches[end - 1].range) - keepEnd))
                loopEnd = end
                break
            }
            start = loopEnd ?? (start + 1)
        }
        guard !removals.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for range in removals.reversed() { result.deleteCharacters(in: range) }
        return (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
