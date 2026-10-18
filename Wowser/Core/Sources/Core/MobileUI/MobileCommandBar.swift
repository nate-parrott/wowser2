import Combine
import SwiftUI

/// The phone command bar, opened by tapping the puck: a card floating near the
/// top (input on top, results below) over a dimmed screen. Empty query shows
/// top sites; typing puts "Ask Wowie" first. Picking a result opens it in a new
/// tab.
struct MobileCommandBar: View {
    var windowID: ID<WindowState>
    var presented: Bool
    var layout: MobileLayout
    var accent: Color
    var onAccent: Color

    @Environment(\.profileID) private var profileID
    @StateObject private var searcher = Searcher()
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(presented ? 0.45 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .allowsHitTesting(presented)

            card
                .frame(width: layout.size.width - 20)
                .scaleEffect(x: presented ? 1 : 0.94, y: presented ? 1 : 0.84, anchor: .center)
                .opacity(presented ? 1 : 0)
                .offset(y: layout.commandBarTop)
                .allowsHitTesting(presented)
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: presented)
        .onAppear {
            searcher.n = 4
            searcher.topSitesEnabled = true
            searcher.preferChat = true
            searcher.windowID = windowID
        }
        .onReceive(profileDataStoreID) { searcher.datastoreProfileID = $0 }
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
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 0.5)
                    .padding(.horizontal, 14)
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button { pick(result) } label: {
                            Text(title(for: result))
                                .font(.system(size: 16))
                                .lineLimit(1)
                                .foregroundStyle(index == 0 ? onAccent : Color.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 14)
    }

    private var results: [SearchResult] {
        Array(searcher.results.prefix(4))
    }

    private func title(for result: SearchResult) -> String {
        switch result.item.content {
        case .askAgent(let q, _): return "Ask Wowie: \u{201C}\(q)\u{201D}"
        case .historyItem(let item) where query.isEmpty: return item.url.hostWithoutWWW
        default: return result.item.title.nilIfEmpty ?? result.item.subtitle ?? ""
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
