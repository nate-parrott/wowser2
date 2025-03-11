import Foundation

public protocol Searchable {
    var primarySearchStrings: [String] { get }
    var secondarySearchStrings: [String] { get }
}

public struct SearchableRecord<T>: Searchable {
    public var item: T
    public var primarySearchStrings: [String]
    public var secondarySearchStrings: [String]

    public init(item: T, primarySearchStrings: [String], secondarySearchStrings: [String]) {
        self.item = item
        self.primarySearchStrings = primarySearchStrings
        self.secondarySearchStrings = secondarySearchStrings
    }

    public var allSearchStrings: [String] {
        primarySearchStrings + secondarySearchStrings
    }
}

public struct SearchResults<T> {
    // A results is considered a top result if one of its primary searchable strings matches the beginning of a primary searchable string. All oher results are `otherResults`
    public var topResults: [T]
    public var otherResults: [T]

    public init(topResults: [T], otherResults: [T]) {
        self.topResults = topResults
        self.otherResults = otherResults
    }

    public var allResults: [T] { topResults + otherResults }

    public func merged(with other: SearchResults<T>) -> SearchResults<T> {
        .init(topResults: self.topResults + other.topResults, otherResults: self.otherResults + other.otherResults)
    }

    public func compactMap<U>(_ fn: (T) -> U?) -> SearchResults<U> {
        .init(topResults: topResults.compactMap(fn), otherResults: otherResults.compactMap(fn))
    }
}

public extension Collection where Element: Searchable {
    func search(query: String) -> SearchResults<Element> {
        let querySeq = NormalizedTokenSequence(string: query, includeTrailingSpace: false)
        var results = SearchResults<Element>(topResults: [], otherResults: [])
        for element in self {
            var isTopMatch = false
            var isOtherMatch = false
            for primary in element.primarySearchStrings {
                let seq = NormalizedTokenSequence(string: primary)
                if let match = seq.match(query: querySeq) {
                    switch match {
                    case .start:
                        isTopMatch = true
                    case .substring:
                        isOtherMatch = true
                    }
                }
            }
            for secondary in element.secondarySearchStrings {
                let seq = NormalizedTokenSequence(string: secondary)
                if seq.match(query: querySeq) != nil {
                    isOtherMatch = true
                }
            }
            if isTopMatch {
                results.topResults.append(element)
            } else if isOtherMatch {
                results.otherResults.append(element)
            }
        }
        return results
    }
}

public struct NormalizedTokenSequence: Equatable, Hashable {
    private var seq: String
    public enum MatchType: Equatable {
        case start
        case substring
    }

    public init(string: String, includeTrailingSpace: Bool = true) {
        let tokens = string.lowercased().components(separatedBy: CharacterSet.tokenizerCharSet)
        self.seq = " " + tokens.joined(separator: " ") + (includeTrailingSpace ? " " : "")
    }

    public func match(query: NormalizedTokenSequence) -> MatchType? {
        if seq.starts(with: query.seq) {
            return .start
        }
        if seq.contains(query.seq) {
            return .substring
        }
        return nil
    }
}

private extension CharacterSet {
    static let tokenizerCharSet = CharacterSet(charactersIn: " \n\t\"“”'‘’?!.,:;[]()-")
}
