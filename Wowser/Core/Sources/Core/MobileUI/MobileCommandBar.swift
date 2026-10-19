import Combine
import SwiftUI

/// The phone command bar, opened by tapping the puck: a card floating near the
/// top (input on top, results below) over a dimmed screen. Empty query shows
/// top sites (common sites until there's history); typing puts "Ask Wowie"
/// first. Picking a result opens it in a new tab. The page behind fades rather
/// than darkening (see MobileContentView).
struct MobileCommandBar: View {
    var windowID: ID<WindowState>
    var presented: Bool
    var layout: MobileLayout
    var accent: Color
    var onAccent: Color

    @Environment(\.profileID) private var profileID
    @StateObject private var searcher = Searcher()
    @StateObject private var topSitesFetcher = TopSitesFetcher()
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .allowsHitTesting(presented)

            card
                .frame(width: layout.size.width - 32)
                .scaleEffect(x: presented ? 1 : 0.94, y: presented ? 1 : 0.84, anchor: .center)
                .opacity(presented ? 1 : 0)
                .offset(y: layout.commandBarTop)
                .allowsHitTesting(presented)
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: presented)
        .sensoryFeedback(.impact(weight: .light), trigger: presented) { _, presented in presented }
        .onAppear {
            searcher.n = 4
            searcher.topSitesEnabled = true
            searcher.windowID = windowID
        }
        .onReceive(profileDataStoreID) { id in
            searcher.datastoreProfileID = id
            topSitesFetcher.profileDataStoreID = id
        }
        .onReceive(topSitesFetcher.$topSites) { sites in
            searcher.topSites = sites.isEmpty ? Self.commonSites : sites
        }
        .onChange(of: query) { _, q in searcher.query = q }
        .onAppearOrChange(of: presented) { presented in
            if presented {
                #if DEBUG
                query = ProcessInfo.processInfo.environment["WOWSER_MOBILE_CMD"] ?? ""
                #else
                query = ""
                #endif
                focused = true
            } else {
                focused = false
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search or enter website name", text: $query)
                    .font(.system(size: 17))
                    .focused($focused)
                    .submitLabel(.go)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.webSearch)
                    #endif
                    .onSubmit { if let first = results.first { pick(first) } else { dismiss() } }
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 56)

            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button { pick(result) } label: {
                            HStack(spacing: 12) {
                                SearchIcon(item: result.item, size: 20, selected: index == 0)
                                    .frame(width: 20, height: 20)
                                Text(title(for: result))
                                    .font(.system(size: 16))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(index == 0 ? onAccent : Color.white)
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                            .background {
                                if index == 0 {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
            }
        }
        .foregroundStyle(.white)
        .mobileGlass(.rounded(26))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 14)
    }

    /// Shown before the history store has anything to offer.
    private static let commonSites: [TopSiteItem] = [
        ("Google", "https://www.google.com"),
        ("YouTube", "https://www.youtube.com"),
        ("Wikipedia", "https://en.wikipedia.org"),
        ("Reddit", "https://www.reddit.com"),
    ].compactMap { title, url in URL(string: url).map { TopSiteItem(title: title, url: $0) } }

    private var results: [SearchResult] {
        Array(searcher.results.prefix(4))
    }

    private func title(for result: SearchResult) -> String {
        switch result.item.content {
        case .askAgent(let q, _): return "Ask Wowie: \u{201C}\(q)\u{201D}"
        case .historyItem(let item) where query.isEmpty: return item.url.hostWithoutWWW
        default:
            let (title, subtitle) = result.item.displayTitleSubtitle
            return title ?? subtitle ?? ""
        }
    }

    private func pick(_ result: SearchResult) {
        BrowserStore.shared.select(result: result, windowID: windowID, forceNewTab: true)
        dismiss()
    }

    private func dismiss() {
        BrowserStore.shared.modify { $0.windows[windowID]?.searchOverlayActive = false }
    }

    private var profileDataStoreID: AnyPublisher<UUID?, Never> {
        guard let profileID else { return Just(nil).eraseToAnyPublisher() }
        return BrowserStore.shared.uiPublisher
            .map { $0.profiles[profileID]?.dataStoreUUID ?? nil }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
