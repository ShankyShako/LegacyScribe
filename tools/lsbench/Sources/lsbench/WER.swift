import Foundation

/// Word error rate over normalized text. Normalization lowercases, drops punctuation,
/// and collapses whitespace so formatting choices (case, commas) don't count as errors.
enum WER {
    static func normalize(_ text: String) -> [String] {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "-", with: " ")
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "'" ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    struct Result: Codable {
        let substitutions: Int
        let deletions: Int
        let insertions: Int
        let referenceWords: Int
        var rate: Double { referenceWords == 0 ? 0 : Double(substitutions + deletions + insertions) / Double(referenceWords) }
    }

    static func compute(reference: String, hypothesis: String) -> Result {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        // Levenshtein DP keeping (cost, subs, dels, ins) per cell.
        typealias Cell = (cost: Int, s: Int, d: Int, i: Int)
        var prev = (0...hyp.count).map { Cell($0, 0, 0, $0) }
        for r in stride(from: 1, through: ref.count, by: 1) {
            var cur = [Cell(r, 0, r, 0)]
            for h in stride(from: 1, through: hyp.count, by: 1) {
                let diag = prev[h - 1]
                let match = ref[r - 1] == hyp[h - 1]
                var best = Cell(diag.cost + (match ? 0 : 1), diag.s + (match ? 0 : 1), diag.d, diag.i)
                let up = prev[h]
                if up.cost + 1 < best.cost { best = Cell(up.cost + 1, up.s, up.d + 1, up.i) }
                let left = cur[h - 1]
                if left.cost + 1 < best.cost { best = Cell(left.cost + 1, left.s, left.d, left.i + 1) }
                cur.append(best)
            }
            prev = cur
        }
        let last = prev[prev.count - 1]
        return Result(substitutions: last.s, deletions: last.d, insertions: last.i, referenceWords: ref.count)
    }
}
