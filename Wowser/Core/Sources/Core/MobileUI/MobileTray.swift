import SwiftUI

// The bottom tray revealed when the puck is dragged up: a fixed toolbar for
// the current page, then one horizontally-paged page per space (fixed name
// row, scrolling favorites + tabs), then fixed space dots.

struct MobileTrayToolbarSnapshot: Equatable {
    var paneID: ID<WebContent>
    var tabID: ID<Tab>
    var url: URL?
    var canGoBack: Bool
    var canGoForward: Bool
}

struct MobileTabRowSnapshot: Equatable, Identifiable {
    var id: ID<Tab>
    var appearance: TabAppearance
}

struct MobileTabGroupSnapshot: Equatable, Identifiable {
    var id: String
    var name: String?
    var tabs: [MobileTabRowSnapshot]
}

struct MobileSpacePageSnapshot: Equatable, Identifiable {
    var id: ID<Profile>
    var name: String
    var favorites: [MobileTabRowSnapshot]
    var groups: [MobileTabGroupSnapshot]
    var currentTabID: ID<Tab>?
}

struct MobileTraySnapshot: Equatable {
    var windowID: ID<WindowState>
    var currentProfileID: ID<Profile>
    var spaces: [MobileSpacePageSnapshot]
    /// nil on agent tabs (and empty pages): no toolbar.
    var toolbar: MobileTrayToolbarSnapshot?
}

extension BrowserState {
    func mobileTraySnapshot(windowID: ID<WindowState>, shareTabsAcrossWindows: Bool) -> MobileTraySnapshot {
        let window = windows[windowID]
        let currentProfileID = window?.profile ?? .defaultProfile
        let spaces = visibleProfiles.map { profile in
            mobileSpacePage(profile: profile, window: window, windowID: windowID, shareTabsAcrossWindows: shareTabsAcrossWindows)
        }
        var toolbar: MobileTrayToolbarSnapshot?
        if let tabID = window?.currentTab, let pane = currentPane(forWindow: windowID),
           !pane.info.isEmptyPage, pane.info.url.flatMap(NativePageKey.init)?.isAgent != true {
            toolbar = MobileTrayToolbarSnapshot(
                paneID: pane.id,
                tabID: tabID,
                url: pane.info.url,
                canGoBack: pane.info.canGoBack,
                canGoForward: pane.info.canGoForward
            )
        }
        return MobileTraySnapshot(windowID: windowID, currentProfileID: currentProfileID, spaces: spaces, toolbar: toolbar)
    }

    private func mobileSpacePage(profile: Profile, window: WindowState?, windowID: ID<WindowState>, shareTabsAcrossWindows: Bool) -> MobileSpacePageSnapshot {
        func row(_ id: ID<Tab>) -> MobileTabRowSnapshot? {
            guard let tab = tabs[id] else { return nil }
            return MobileTabRowSnapshot(id: id, appearance: tab.appearance())
        }
        let perProfile = window?.perProfileData[profile.id]
        let tabIDs = shareTabsAcrossWindows
            ? sharedSidebarTabIDs(windowID: windowID, profileID: profile.id)
            : (perProfile?.tabs ?? [])
        return MobileSpacePageSnapshot(
            id: profile.id,
            name: profile.displayName,
            favorites: (profile.manualFavorites + profile.autoFavorites).compactMap(row),
            groups: mobileTabGroups(tabIDs).map { group in
                MobileTabGroupSnapshot(id: group.id, name: group.name, tabs: group.tabIDs.compactMap(row))
            },
            currentTabID: perProfile?.currentTab
        )
    }

    /// Same grouping as the desktop sidebar: a header wherever the AI group
    /// name changes, once there are enough tabs to organize.
    private func mobileTabGroups(_ tabIDs: [ID<Tab>]) -> [TabGroup] {
        guard tabIDs.count >= UIConstants.autoOrgMinTabCount else {
            return [TabGroup(id: "0", tabIDs: tabIDs)]
        }
        var groups: [TabGroup] = []
        var name: String?
        var current: [ID<Tab>] = []
        for id in tabIDs {
            let groupName = tabs[id]?.aiTags?.groupName
            if groupName != name, !current.isEmpty {
                groups.append(TabGroup(id: "group-\(name ?? "")-\(groups.count)", name: name, tabIDs: current))
                current = []
            }
            name = groupName
            current.append(id)
        }
        if !current.isEmpty {
            groups.append(TabGroup(id: "group-\(name ?? "")-\(groups.count)", name: name, tabIDs: current))
        }
        return groups
    }
}

// MARK: - Tray

struct MobileTray: View {
    var snapshot: MobileTraySnapshot
    var accent: Color
    /// Called after the user picks a tab, so the tray can close.
    var didPick: () -> Void
    var openSettings: () -> Void

    @State private var visibleProfileID: ID<Profile>?

    var body: some View {
        VStack(spacing: 0) {
            if let toolbar = snapshot.toolbar {
                MobileTrayToolbar(snapshot: toolbar, windowID: snapshot.windowID)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
            }
            pager
            dots
                .padding(.bottom, 6)
        }
        .foregroundStyle(.white)
        .onAppearOrChange(of: snapshot.currentProfileID) { visibleProfileID = $0 }
        .onChange(of: visibleProfileID) { _, id in
            guard let id, id != snapshot.currentProfileID else { return }
            BrowserStore.shared.modify { state in
                state.windows[snapshot.windowID]?.profile = id
                state.windows[snapshot.windowID]?.showingNewProfilePage = nil
            }
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(snapshot.spaces) { space in
                    MobileSpacePage(
                        snapshot: space,
                        windowID: snapshot.windowID,
                        accent: accent,
                        didPick: didPick,
                        openSettings: openSettings
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(space.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $visibleProfileID)
    }

    private var dots: some View {
        HStack(spacing: 0) {
            ForEach(snapshot.spaces) { space in
                let selected = space.id == visibleProfileID
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) { visibleProfileID = space.id }
                } label: {
                    Circle()
                        .fill(selected ? accent : Color.white.opacity(0.4))
                        .frame(width: 7, height: 7)
                        .frame(width: 34, height: 34)
                        .mobileGlass(.capsule, enabled: selected)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(space.name)
            }
            Button {
                var newID: ID<Profile>?
                BrowserStore.shared.modify { state in
                    newID = state.createNewProfile(sharingLoginsWith: snapshot.currentProfileID)
                }
                if let newID {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) { visibleProfileID = newID }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Space")
        }
    }
}

// MARK: - Toolbar

private struct MobileTrayToolbar: View {
    var snapshot: MobileTrayToolbarSnapshot
    var windowID: ID<WindowState>

    var body: some View {
        HStack(spacing: 0) {
            iconButton("chevron.backward", label: "Back", size: 17, weight: .semibold) {
                webContent?.goBack()
            }
            .opacity(snapshot.canGoBack ? 1 : 0.35)
            .disabled(!snapshot.canGoBack)

            if snapshot.canGoForward {
                iconButton("chevron.forward", label: "Forward", size: 17, weight: .semibold) {
                    webContent?.goForward()
                }
            }

            Button {
                BrowserStore.shared.modify { $0.windows[windowID]?.searchOverlayActive = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.6))
                    Text(snapshot.url?.hostWithoutWWW ?? "")
                        .font(.system(size: 15))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 2)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit address")

            iconButton("link", label: "Copy link", size: 15, weight: .medium) {
                #if os(iOS)
                if let url = snapshot.url { UIPasteboard.general.url = url }
                #endif
            }
            .foregroundStyle(Color.white.opacity(0.75))

            if let url = snapshot.url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 42, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share")
            }

            Menu {
                Button("Reload", systemImage: "arrow.clockwise") { webContent?.reload() }
                Button("Close Tab", systemImage: "xmark", role: .destructive) { closeTab(tabID: snapshot.tabID) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Page options")
        }
        .padding(.horizontal, 2)
        .frame(height: 46)
        .mobileGlass(.capsule)
    }

    private var webContent: WebContent? {
        BrowserStore.shared.existingWebContent(forId: snapshot.paneID)
    }

    private func iconButton(_ symbol: String, label: String, size: CGFloat, weight: Font.Weight, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .frame(width: 42, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Space page

private struct MobileSpacePage: View {
    var snapshot: MobileSpacePageSnapshot
    var windowID: ID<WindowState>
    var accent: Color
    var didPick: () -> Void
    var openSettings: () -> Void

    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        MobileFavoritesGrid(tabs: snapshot.favorites, windowID: windowID, currentTabID: snapshot.currentTabID, accent: accent, didPick: didPick)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                        ForEach(snapshot.groups) { group in
                            if let name = group.name {
                                Text(name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.6))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(EdgeInsets(top: 14, leading: 14, bottom: 6, trailing: 14))
                            }
                            ForEach(group.tabs) { tab in
                                MobileTabRow(tab: tab, selected: tab.id == snapshot.currentTabID, accent: accent) {
                                    didClickTabToSelect(tabID: tab.id, windowID: windowID)
                                    didPick()
                                }
                                .id(tab.id)
                            }
                        }
                        newTabHint
                    }
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.hidden)
                .mask(feather)
                .onAppear { reveal(proxy) }
                .onChange(of: snapshot.currentTabID) { _, _ in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) { reveal(proxy) }
                }
            }
        }
        .alert("Rename Space", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                BrowserStore.shared.modify { $0.profiles[snapshot.id]?.title = name.isEmpty ? nil : name }
            }
        }
    }

    /// Keep the current tab in view: centered in this space's list.
    private func reveal(_ proxy: ScrollViewProxy) {
        if let id = snapshot.currentTabID { proxy.scrollTo(id, anchor: .center) }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(snapshot.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .lineLimit(1)
            Menu {
                Button("Rename Space", systemImage: "pencil") {
                    newName = snapshot.name
                    renaming = true
                }
                Button("New Tab", systemImage: "plus") {
                    BrowserStore.shared.modify { $0.windows[windowID]?.searchOverlayActive = true }
                    didPick()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Space options")
            Spacer(minLength: 8)
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .frame(height: 44)
    }

    private var newTabHint: some View {
        HStack(spacing: 5) {
            Text("Tap")
            Image("Fruit", bundle: .module)
                .resizable()
                .frame(width: 16, height: 16)
                .opacity(0.6)
            Text("to make a new tab")
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.white.opacity(0.36))
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.bottom, 48)
    }

    private var feather: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 48)
        }
    }
}

// MARK: - Favorites & rows

private struct MobileFavoritesGrid: View {
    var tabs: [MobileTabRowSnapshot]
    var windowID: ID<WindowState>
    var currentTabID: ID<Tab>?
    var accent: Color
    var didPick: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { tab in
                        Button {
                            if tab.id == currentTabID {
                                resetTabToBaseURL(tabID: tab.id, windowID: windowID)
                            } else {
                                didClickTabToSelect(tabID: tab.id, windowID: windowID)
                            }
                            didPick()
                        } label: {
                            MobileTabIcon(icon: tab.appearance.icon, size: 26)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .mobileGlass(.capsule, tint: tab.id == currentTabID ? accent.opacity(0.5) : nil)
                        .accessibilityLabel(tab.appearance.title)
                    }
                }
            }
        }
    }

    /// Up to 4 per row; never leave a lone tile on the last row.
    private var rows: [[MobileTabRowSnapshot]] {
        var rows = stride(from: 0, to: tabs.count, by: 4).map { Array(tabs[$0..<min($0 + 4, tabs.count)]) }
        if rows.count > 1, rows[rows.count - 1].count == 1, let moved = rows[rows.count - 2].popLast() {
            rows[rows.count - 1].insert(moved, at: 0)
        }
        return rows
    }
}

private struct MobileTabRow: View {
    var tab: MobileTabRowSnapshot
    var selected: Bool
    var accent: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MobileTabIcon(icon: tab.appearance.icon, size: 20)
                    .opacity(tab.appearance.isUnloaded || tab.appearance.isGhost ? 0.55 : 1)
                Text(tab.appearance.title)
                    .font(.system(size: 16))
                    .italic(tab.appearance.isCustomTitle)
                    .lineLimit(1)
                    .opacity(tab.appearance.isUnloaded || tab.appearance.isGhost ? 0.65 : 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .mobileGlass(.rounded(14), tint: accent.opacity(0.45), enabled: selected)
        .contextMenu {
            Button("Close Tab", systemImage: "xmark", role: .destructive) { closeTab(tabID: tab.id) }
        }
    }
}

/// A tab's icon at phone size (favicons sharp at any size; symbols scaled).
struct MobileTabIcon: View {
    var icon: TabAppearance.Icon
    var size: CGFloat

    var body: some View {
        switch icon {
        case .favicon(let url):
            FaviconView(faviconURL: url, size: size)
        default:
            TabIconView(icon: icon)
                .scaleEffect(size / 16)
                .frame(width: size, height: size)
        }
    }
}
