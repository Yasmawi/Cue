import Foundation

/// Fast subsequence matcher tuned for effect names ("gb" → "Gaussian Blur",
/// "xdis" → "Cross Dissolve"). Multi-word queries must match every word.
enum FuzzyMatcher {
    struct Match {
        var score: Int
        var ranges: [Int]   // matched character offsets in the name, for highlighting
    }

    static func match(_ query: String, in name: String, category: String = "") -> Match? {
        let tokens = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        if tokens.isEmpty { return Match(score: 0, ranges: []) }
        let hay = Array(name.lowercased())
        let nameChars = Array(name)
        let original = nameChars.count == hay.count ? nameChars : hay
        let catLower = category.lowercased()
        var total = 0
        var hits = Set<Int>()
        for token in tokens {
            if let m = score(Array(token), hay, original) {
                total += m.score
                hits.formUnion(m.ranges)
            } else if catLower.contains(token) {
                total += 4 // matched the category ("blur" finds everything in Blur & Sharpen)
            } else {
                return nil
            }
        }
        // Shorter names win ties: "Blur" beats "Directional Blur" for "blur".
        total -= min(hay.count / 4, 8)
        return Match(score: total, ranges: hits.sorted())
    }

    private static func isBoundary(_ chars: [Character], _ i: Int) -> Bool {
        if i == 0 { return true }
        let prev = chars[i - 1]
        if prev == " " || prev == "-" || prev == "_" || prev == "." || prev == "(" || prev == "&" || prev == "/" { return true }
        return prev.isLowercase && chars[i].isUppercase
    }

    private static func score(_ needle: [Character], _ hay: [Character], _ original: [Character]) -> Match? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }

        // Exact substring gets a big, simple bonus.
        let hayString = String(hay)
        let needleString = String(needle)
        if let r = hayString.range(of: needleString) {
            let start = hayString.distance(from: hayString.startIndex, to: r.lowerBound)
            var s = 30 + needle.count * 6
            if start == 0 { s += 25 } else if isBoundary(original, start) { s += 15 }
            if needle.count == hay.count { s += 30 }
            return Match(score: s, ranges: Array(start..<(start + needle.count)))
        }

        // Greedy subsequence, preferring word starts.
        var positions: [Int] = []
        var hi = 0
        var s = 0
        var lastMatch = -2
        for (ni, ch) in needle.enumerated() {
            // look ahead for a boundary occurrence of ch before falling back to the next occurrence
            var found = -1
            var j = hi
            var firstAny = -1
            while j < hay.count {
                if hay[j] == ch {
                    if firstAny < 0 { firstAny = j }
                    if isBoundary(original, j) { found = j; break }
                    // don't skip ahead past a consecutive continuation
                    if j == lastMatch + 1 { found = j; break }
                }
                j += 1
            }
            if found < 0 { found = firstAny }
            if found < 0 { return nil }
            if found == lastMatch + 1 { s += 8 }            // consecutive
            if isBoundary(original, found) { s += 10 }       // word start
            if ni == 0 && found == 0 { s += 12 }             // prefix
            s -= min(found - hi, 6)                          // gaps cost a little
            positions.append(found)
            lastMatch = found
            hi = found + 1
        }
        return Match(score: s + needle.count * 2, ranges: positions)
    }
}
