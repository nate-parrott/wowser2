import Foundation

/// Fractional indexing: order keys are strings that sort lexicographically,
/// and there's always a key strictly between any two. Moving an item rewrites
/// only that item's key, so concurrent moves on two devices merge cleanly
/// (per-item last-writer-wins) instead of fighting over a whole array.
///
/// A key is the digits of a base-62 fraction in (0, 1), e.g. "V" ≈ 0.5.
/// Keys never end in the zero digit, which guarantees room below any key.
public enum FractionalIndex {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let base = digits.count
    private static let digitValue: [Character: Int] = {
        var out = [Character: Int]()
        for (i, c) in digits.enumerated() { out[c] = i }
        return out
    }()

    public static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.last != digits[0] && key.allSatisfy { digitValue[$0] != nil }
    }

    /// A key strictly between `a` and `b`. nil means "the start" / "the end".
    /// Invalid inputs (or a >= b) are treated as missing bounds, so callers
    /// always get a usable key.
    public static func key(between a: String?, and b: String?) -> String {
        var a = a.flatMap { isValid($0) ? $0 : nil }
        var b = b.flatMap { isValid($0) ? $0 : nil }
        if let lo = a, let hi = b, lo >= hi {
            // Corrupt or equal bounds: give up on the upper bound.
            b = nil
            a = max(lo, hi)
        }
        switch (a, b) {
        case (nil, nil): return String(digits[base / 2])
        case let (lo?, nil): return after(lo)
        case let (nil, hi?): return before(hi)
        case let (lo?, hi?): return midpoint(Array(lo), Array(hi))
        }
    }

    /// Appends are the common case (new tab at the end), so step the last
    /// digit up instead of halving the gap: keys grow one char per ~60 appends.
    private static func after(_ a: String) -> String {
        let last = digitValue[a.last!]!
        if last < base - 1 { return String(a.dropLast()) + String(digits[last + 1]) }
        return a + String(digits[1])
    }

    /// Mirror of `after` for prepends. Never produces a trailing zero digit.
    private static func before(_ b: String) -> String {
        let last = digitValue[b.last!]!
        if last > 1 { return String(b.dropLast()) + String(digits[last - 1]) }
        return String(b.dropLast()) + String(digits[0]) + String(digits[base - 1])
    }

    /// `count` ascending keys strictly between `a` and `b`, spread evenly so
    /// later inserts between them stay short.
    public static func keys(between a: String?, and b: String?, count: Int) -> [String] {
        guard count > 0 else { return [] }
        if count == 1 { return [key(between: a, and: b)] }
        let mid = key(between: a, and: b)
        let left = keys(between: a, and: mid, count: count / 2)
        let right = keys(between: mid, and: b, count: count - count / 2 - 1)
        return left + [mid] + right
    }

    /// Digits strictly between a and b (b == nil means 1.0). `a` may be empty
    /// (0.0). Neither may end in the zero digit.
    private static func midpoint(_ a: [Character], _ b: [Character]?) -> String {
        if let b {
            // Shared prefix: recurse on the remainder.
            var n = 0
            while n < b.count, (n < a.count ? a[n] : digits[0]) == b[n] { n += 1 }
            if n > 0 {
                let prefix = String(b[0..<n])
                let restA = n < a.count ? Array(a[n...]) : []
                return prefix + midpoint(restA, Array(b[n...]))
            }
        }
        let da = a.first.flatMap { digitValue[$0] } ?? 0
        let db = b?.first.flatMap { digitValue[$0] } ?? base
        if db - da > 1 {
            return String(digits[(da + db) / 2])
        }
        // Adjacent first digits.
        if let b, b.count > 1 {
            return String(b[0])
        }
        // Keep a's first digit and find room after it.
        return String(digits[da]) + midpoint(a.isEmpty ? [] : Array(a.dropFirst()), nil)
    }
}

/// Order keys for a list, reusing existing keys where they're still in order.
public enum SyncOrdering {
    /// Assign an order key to each item of `items` (in their new order),
    /// keeping `existing[item]` for the longest run of items whose existing
    /// keys are already ascending, and minting keys for the rest. Ties in
    /// existing keys are broken by item id, matching how lists materialize.
    public static func assignKeys(items: [String], existing: [String: String]) -> [String: String] {
        // Longest increasing subsequence (patience sort) over items that have keys.
        let candidates: [(idx: Int, sortKey: OrderSortKey)] = items.enumerated().compactMap { i, item in
            guard let k = existing[item], FractionalIndex.isValid(k) else { return nil }
            return (i, OrderSortKey(order: k, id: item))
        }
        var tails: [Int] = []          // index into candidates
        var prev = [Int](repeating: -1, count: candidates.count)
        for (ci, c) in candidates.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if candidates[tails[mid]].sortKey < c.sortKey { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[ci] = tails[lo - 1] }
            if lo == tails.count { tails.append(ci) } else { tails[lo] = ci }
        }
        var kept = Set<Int>()   // item indices whose key is kept
        var cur = tails.last ?? -1
        while cur >= 0 {
            kept.insert(candidates[cur].idx)
            cur = prev[cur]
        }
        // Kept neighbors that tie on key (ordered only by id) leave no room
        // for a run of new keys between them: re-key the upper one too.
        var changed = true
        while changed {
            changed = false
            let keptSorted = kept.sorted()
            for (lo, hi) in zip(keptSorted, keptSorted.dropFirst()) where hi > lo + 1 && existing[items[lo]] == existing[items[hi]] {
                kept.remove(hi)
                changed = true
                break
            }
        }

        var result = [String: String]()
        var i = 0
        var lastKey: String? = nil
        while i < items.count {
            if kept.contains(i) {
                let k = existing[items[i]]!
                result[items[i]] = k
                lastKey = k
                i += 1
                continue
            }
            // A run of items needing keys: [i, j)
            var j = i
            while j < items.count, !kept.contains(j) { j += 1 }
            let upper = j < items.count ? existing[items[j]] : nil
            let newKeys = FractionalIndex.keys(between: lastKey, and: upper, count: j - i)
            for (offset, k) in newKeys.enumerated() {
                result[items[i + offset]] = k
            }
            lastKey = newKeys.last ?? lastKey
            i = j
        }
        return result
    }
}

/// How synced lists sort: by order key, then by id (concurrent inserts at the
/// same spot can mint identical keys).
public struct OrderSortKey: Comparable, Hashable {
    public var order: String
    public var id: String
    public static func < (a: OrderSortKey, b: OrderSortKey) -> Bool {
        a.order != b.order ? a.order < b.order : a.id < b.id
    }
}
