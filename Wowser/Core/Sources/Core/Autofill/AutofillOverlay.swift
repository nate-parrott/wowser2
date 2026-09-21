#if os(macOS)
import SwiftUI

/// Sits over a pane's webview (see `WrappedWebView`) and draws the autofill
/// suggestion menu under the focused field, or the searchable `<select>` menu
/// under a dropdown. Everything outside the menus passes clicks through to the
/// page. The webview keeps first responder; keys reach the menus via
/// `AutofillSession.handleKeyDown`.
struct AutofillOverlay: View {
    var webContent: WebContent

    var body: some View {
        if let session = webContent.autofill {
            AutofillOverlayContent(session: session, webContent: webContent)
        }
    }
}

private struct AutofillOverlayContent: View {
    @ObservedObject var session: AutofillSession
    var webContent: WebContent

    var body: some View {
        GeometryReader { geo in
            let zoom = webContent.wkWebview?.pageZoom ?? 1
            ZStack(alignment: .topLeading) {
                if let menu = session.menu, let rect = menu.field.rect {
                    let layout = MenuLayout(anchor: rect, zoom: zoom, container: geo.size, rowCount: menu.suggestions.count, rowHeight: 36, extra: 30)
                    SuggestionMenuView(menu: menu, session: session)
                        .frame(width: layout.width)
                        .offset(x: layout.x, y: layout.y)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: layout.above ? .bottom : .top)))
                        .id(menu.field.signature)
                }
                if let open = session.selectMenu {
                    let count = min(open.filteredOptions.count, 9)
                    let layout = MenuLayout(anchor: open.anchor, zoom: zoom, container: geo.size, rowCount: max(count, 1), rowHeight: 28, extra: 44 + 8)
                    SelectMenuView(menu: open, session: session, maxListHeight: layout.listHeight(rowHeight: 28))
                        .frame(width: layout.width)
                        .offset(x: layout.x, y: layout.y)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: layout.above ? .bottom : .top)))
                        .id("select-\(open.info.field.signature)")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(.spring(duration: 0.18, bounce: 0.15), value: session.menu?.field.signature)
            .animation(.spring(duration: 0.18, bounce: 0.15), value: session.selectMenu?.info.field.signature)
        }
    }
}

/// Places a menu under (or, without room, above) a field rect.
private struct MenuLayout {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var above: Bool
    var availableHeight: CGFloat

    init(anchor: AutofillRect, zoom: CGFloat, container: CGSize, rowCount: Int, rowHeight: CGFloat, extra: CGFloat) {
        let field = CGRect(x: anchor.x * zoom, y: anchor.y * zoom, width: anchor.width * zoom, height: anchor.height * zoom)
        width = min(max(field.width, 280), min(460, max(200, container.width - 16)))
        x = min(max(8, field.minX), max(8, container.width - width - 8))
        let estimated = CGFloat(rowCount) * rowHeight + extra
        let below = container.height - field.maxY - 6
        let aboveSpace = field.minY - 6
        if below >= min(estimated, 160) || below >= aboveSpace {
            above = false
            y = field.maxY + 4
            availableHeight = max(80, below - 8)
        } else {
            above = true
            let h = min(estimated, aboveSpace - 8)
            y = max(8, field.minY - 4 - h)
            availableHeight = max(80, aboveSpace - 8)
        }
    }

    func listHeight(rowHeight: CGFloat) -> CGFloat {
        min(rowHeight * 9, max(rowHeight * 3, availableHeight - 52))
    }
}

// MARK: - Suggestion menu

private struct SuggestionMenuView: View {
    var menu: AutofillSession.SuggestionMenu
    var session: AutofillSession

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(Array(menu.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionRow(suggestion: suggestion, highlighted: index == menu.highlighted)
                        .onHover { if $0 { session.highlight(index) } }
                        .onTapGesture { Task { await session.accept(suggestion) } }
                }
            }
            .padding(6)
            Divider().opacity(0.4)
            HStack(spacing: 10) {
                Label("choose", systemImage: "arrow.up.arrow.down")
                Label("fill", systemImage: "return")
                Label("hide", systemImage: "escape")
                Spacer()
                Image(systemName: "lock.fill").opacity(0.6)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .labelStyle(CompactKeyLabelStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .modifier(AutofillGlassBackground())
    }
}

private struct SuggestionRow: View {
    var suggestion: AutofillSuggestion
    var highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20)
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = suggestion.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(highlighted ? 0.85 : 0.6)
                }
            }
            Spacer(minLength: 0)
            if highlighted {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.8)
            }
        }
        .foregroundStyle(highlighted ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(highlighted ? Color.accentColor : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Select menu

private struct SelectMenuView: View {
    var menu: AutofillSession.SelectMenu
    var session: AutofillSession
    var maxListHeight: CGFloat

    var body: some View {
        let options = menu.filteredOptions
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if menu.filter.isEmpty {
                    Text("Type to filter…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(menu.filter)
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: 15)
                    .modifier(BlinkingCaret())
                Spacer(minLength: 0)
                Text("\(options.count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().opacity(0.4)
            if options.isEmpty {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(options.enumerated()), id: \.element.index) { index, option in
                                let showGroup = option.group != nil && (index == 0 || options[index - 1].group != option.group)
                                if showGroup, let group = option.group {
                                    Text(group)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.top, index == 0 ? 2 : 8)
                                        .padding(.bottom, 2)
                                }
                                SelectOptionRow(option: option, highlighted: index == menu.highlighted, selected: option.index == menu.info.selectedIndex)
                                    .id(option.index)
                                    .onHover { if $0 { session.highlightSelectOption(index) } }
                                    .onTapGesture { session.chooseSelectOption(option) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: maxListHeight)
                    .onChange(of: menu.highlighted) { _ in
                        if let o = options[safe: menu.highlighted] { proxy.scrollTo(o.index, anchor: .center) }
                    }
                    .onAppear {
                        if let o = options[safe: menu.highlighted] { proxy.scrollTo(o.index, anchor: .center) }
                    }
                }
            }
        }
        .modifier(AutofillGlassBackground())
    }
}

private struct SelectOptionRow: View {
    var option: AutofillFieldQuery.SelectOption
    var highlighted: Bool
    var selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .opacity(selected ? 1 : 0)
                .frame(width: 12)
            Text(option.label.isEmpty ? " " : option.label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(option.disabled ? 0.4 : 1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(highlighted ? .white : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Color.accentColor : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Chrome

/// Liquid Glass card used by both menus.
private struct AutofillGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .background {
                Color.clear
                    .glassEffect(.regular, in: shape)
            }
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

private struct CompactKeyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.primary.opacity(0.08)))
            configuration.title
        }
    }
}

private struct BlinkingCaret: ViewModifier {
    @State private var on = true
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { on = false }
            }
    }
}
#endif
