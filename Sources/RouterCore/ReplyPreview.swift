import Foundation
import NaturalLanguage

/// Short, display-only excerpt of an assistant reply for notification bodies.
/// Never persisted: callers must not store the result in settings or History.
public enum ReplyPreview {
    public static func lastSentences(_ reply: String, count: Int = 1, limit: Int = 100) -> String? {
        var prose: [String] = []
        var paragraph: [String] = []
        var inFence = false, inListItem = false
        // A block (paragraph, heading, list item) ends its own sentence even without closing punctuation.
        func flush() {
            inListItem = false
            guard !paragraph.isEmpty else { return }
            var text = paragraph.joined(separator: " "); paragraph.removeAll()
            // Look past closing quotes/brackets: `(see above.)` already ends a sentence.
            let core = text.replacingOccurrences(of: #"[)\]"'\x{201D}\x{2019}\x{00BB}]+$"#, with: "", options: .regularExpression)
            if let last = core.last, !".!?:;…".contains(last) { text += "." }
            prose.append(text)
        }
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { flush(); inFence.toggle(); continue }
            if inFence { continue }
            if line.isEmpty || line.hasPrefix("|") { flush(); continue }
            let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil
            let listItem = line.range(of: #"^([-*+]\s+|\d+[.)]\s+)"#, options: .regularExpression) != nil
            // Hard-wrapped prose continues its paragraph; an unindented line after a list item starts a new block.
            if heading || listItem || (inListItem && raw.first?.isWhitespace != true) { flush() }
            var text = line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            paragraph.append(text)
            if heading { flush() } else if listItem { inListItem = true }
        }
        flush()
        let joined = prose.joined(separator: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !joined.isEmpty else { return nil }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = joined
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: joined.startIndex..<joined.endIndex) { range, _ in
            let s = joined[range].trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        var result = sentences.suffix(max(count, 1)).joined(separator: " ")
        // Keep the start: macOS banners show about two lines, and a sentence's opening carries its meaning.
        if result.count > limit {
            var head = String(result.prefix(limit))
            if let space = head.lastIndex(of: " ") { head = String(head[..<space]) }
            // Trim only the cut end: an opening quote or parenthesis belongs to the sentence.
            result = head.replacingOccurrences(of: #"[\p{P}\s]+$"#, with: "", options: .regularExpression) + "…"
        }
        return result.isEmpty ? nil : result
    }
}
