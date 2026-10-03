#if os(macOS)
import SwiftUI

// MARK: - Field dropdown
//
// The one dropdown that hangs off a text field inside a page. Autofill
// suggestions, the searchable `<select>` replacement and live dictation all
// render with these pieces, and `FieldDropdownOverlay` decides which of them
// owns the slot under the focused field. See FieldDropdownPreviews.swift.

/// Where a dropdown goes: under the field (or above it, when there isn't room),
/// at least as wide as the field, clamped to the container.
struct FieldDropdownPlacement: Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var above: Bool
    var availableHeight: CGFloat

    /// `field` is in container coordinates (page zoom already applied).
    init(field: CGRect, container: CGSize, estimatedHeight: CGFloat, minWidth: CGFloat = 280, maxWidth: CGFloat = 460) {
        width = min(max(field.width, minWidth), min(maxWidth, max(200, container.width - 16)))
        x = min(max(8, field.minX), max(8, container.width - width - 8))
        let below = container.height - field.maxY - 6
        let aboveSpace = field.minY - 6
        if below >= min(estimatedHeight, 160) || below >= aboveSpace {
            above = false
            y = field.maxY + 4
            availableHeight = max(80, below - 8)
        } else {
            above = true
            let h = min(estimatedHeight, aboveSpace - 8)
            y = max(8, field.minY - 4 - h)
            availableHeight = max(80, aboveSpace - 8)
        }
    }

    /// Height for a scrolling list inside the dropdown (header/footer excluded).
    func listHeight(rowHeight: CGFloat, maxRows: Int = 9, chrome: CGFloat = 52) -> CGFloat {
        min(rowHeight * CGFloat(maxRows), max(rowHeight * 3, availableHeight - chrome))
    }
}

extension AutofillRect {
    /// CSS-pixel rect → view points.
    func zoomed(_ zoom: CGFloat) -> CGRect {
        CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
    }
}

extension WebContent.Info.FocusedEditable {
    func zoomed(_ zoom: CGFloat) -> CGRect {
        CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
    }
}

// MARK: - Chrome

/// Liquid Glass card every field dropdown sits in.
struct FieldDropdownCard: ViewModifier {
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

extension View {
    func fieldDropdownCard() -> some View { modifier(FieldDropdownCard()) }
}

// MARK: - Rows

/// A suggestion-style row: icon, title, optional subtitle; accent fill when highlighted.
struct FieldDropdownRow: View {
    var systemImage: String?
    var title: String
    var subtitle: String?
    var highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
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

/// A dense list-option row (the `<select>` menu): checkmark for the current value.
struct FieldDropdownOptionRow: View {
    var label: String
    var highlighted: Bool
    var selected: Bool
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .opacity(selected ? 1 : 0)
                .frame(width: 12)
            Text(label.isEmpty ? " " : label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(disabled ? 0.4 : 1)
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

/// Section title inside a list (e.g. an `<optgroup>`).
struct FieldDropdownSectionHeader: View {
    var title: String
    var isFirst: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, isFirst ? 2 : 8)
            .padding(.bottom, 2)
    }
}

// MARK: - Header / footer

/// Type-to-filter header. The filter text is typed into the page's key stream
/// (the webview keeps first responder), so this only displays it.
struct FieldDropdownFilterHeader: View {
    var filter: String
    var placeholder: String = "Type to filter…"
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if filter.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
            } else {
                Text(filter)
            }
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: 15)
                .padding(.leading, -7)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

struct FieldDropdownKeyHint: Hashable {
    var title: String
    var systemImage: String

    static let choose = FieldDropdownKeyHint(title: "choose", systemImage: "arrow.up.arrow.down")
    static let fill = FieldDropdownKeyHint(title: "fill", systemImage: "return")
    static let hide = FieldDropdownKeyHint(title: "hide", systemImage: "escape")
    static let insert = FieldDropdownKeyHint(title: "insert", systemImage: "return")
    static let cancel = FieldDropdownKeyHint(title: "cancel", systemImage: "escape")
}

/// Keyboard hints along the bottom of a dropdown, with an optional trailing glyph.
struct FieldDropdownFooter: View {
    var hints: [FieldDropdownKeyHint]
    var trailingSystemImage: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(hints, id: \.self) { hint in
                Label(hint.title, systemImage: hint.systemImage)
            }
            Spacer()
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage).opacity(0.6)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .labelStyle(CompactKeyLabelStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct CompactKeyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
//                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.primary.opacity(0.08)))
            
            configuration.title
        }
    }
}

// MARK: - Composite dropdowns

/// Suggestion list + key hints (autofill).
struct FieldDropdownSuggestionList: View {
    struct Item: Identifiable, Equatable {
        var id: String
        var systemImage: String?
        var title: String
        var subtitle: String?
    }

    var items: [Item]
    var highlighted: Int
    var hints: [FieldDropdownKeyHint] = [.choose, .fill, .hide]
    var trailingSystemImage: String? = nil
    var onHover: (Int) -> Void = { _ in }
    var onChoose: (Int) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    FieldDropdownRow(systemImage: item.systemImage, title: item.title, subtitle: item.subtitle, highlighted: index == highlighted)
                        .onHover { if $0 { onHover(index) } }
                        .onTapGesture { onChoose(index) }
                }
            }
            .padding(6)
            Divider().opacity(0.4)
            FieldDropdownFooter(hints: hints, trailingSystemImage: trailingSystemImage)
        }
        .fieldDropdownCard()
    }

    /// Estimated height, for placement before layout.
    static func estimatedHeight(rows: Int) -> CGFloat { CGFloat(rows) * 36 + 30 }
}

/// Filterable option list (the searchable `<select>`).
struct FieldDropdownOptionList: View {
    struct Option: Identifiable, Equatable {
        var id: Int
        var label: String
        var group: String?
        var disabled: Bool
    }

    var filter: String
    var options: [Option]
    var highlighted: Int
    var selectedID: Int?
    var maxListHeight: CGFloat
    var onHover: (Int) -> Void = { _ in }
    var onChoose: (Option) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            FieldDropdownFilterHeader(filter: filter, count: options.count)
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
                            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                                if let group = option.group, index == 0 || options[index - 1].group != group {
                                    FieldDropdownSectionHeader(title: group, isFirst: index == 0)
                                }
                                FieldDropdownOptionRow(label: option.label, highlighted: index == highlighted, selected: option.id == selectedID, disabled: option.disabled)
                                    .id(option.id)
                                    .onHover { if $0 { onHover(index) } }
                                    .onTapGesture { onChoose(option) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: maxListHeight)
                    .onChange(of: highlighted) { _, new in
                        if let o = options[safe: new] { proxy.scrollTo(o.id, anchor: .center) }
                    }
                    .onAppear {
                        if let o = options[safe: highlighted] { proxy.scrollTo(o.id, anchor: .center) }
                    }
                }
            }
        }
        .fieldDropdownCard()
    }

    static let rowHeight: CGFloat = 28
    static func estimatedHeight(rows: Int) -> CGFloat { CGFloat(max(1, min(rows, 9))) * rowHeight + 52 }
}

private struct DictationIcon: View {
    var listening: Bool
    
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    var body: some View {
        let darkMode = colorScheme == .dark
        Image(systemName: "mic.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(listening ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            .frame(width: 20)
            .brightness(listening && darkMode ? 0.3 : 0)
            .shadow(color: Color.red.opacity(listening ? (darkMode ? 1 : 0.5) : 0), radius: 4, x: 0, y: 0)
//            .padding(.top, 1)
    }
}

/// Live dictation: mic + running transcript + key hints.
struct FieldDropdownDictation: View {
    var transcript: String
    var phase: DictationController.Phase
    /// What Return does: insert into a field, or send to the agent/terminal.
    var commitHint: FieldDropdownKeyHint = .insert

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
//                Image(systemName: "mic.fill")
//                    .font(.system(size: 13, weight: .semibold))
//                    .foregroundStyle(phase == .listening ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
//                    .frame(width: 20)
                DictationIcon(listening: phase == .listening)
                    .padding(.top, 1)
                Text(displayText)
                    .font(.system(size: 13))
                    .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                    .lineLimit(4)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if phase == .listening {
                Divider().opacity(0.4)
                FieldDropdownFooter(hints: [commitHint, .cancel], trailingSystemImage: nil)
            }
        }
        .fieldDropdownCard()
    }

    private var displayText: String {
        switch phase {
        case .starting: return "Starting…"
        case .committing: return transcript.isEmpty ? "Finishing…" : transcript
        case .listening, .idle: return transcript.isEmpty ? "Listening…" : transcript
        }
    }

    static let estimatedHeight: CGFloat = 76
}

// Every component at once; more states (with a mock field) live in FieldDropdownPreviews.swift.
#Preview("Gallery") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            FieldDropdownSuggestionList(items: FieldDropdownSamples.logins, highlighted: 0)
            FieldDropdownSuggestionList(items: FieldDropdownSamples.identity, highlighted: 2, trailingSystemImage: nil)
            FieldDropdownOptionList(filter: "an", options: FieldDropdownSamples.countries.filter { $0.label.lowercased().contains("an") }, highlighted: 1, selectedID: 3, maxListHeight: 180)
            FieldDropdownDictation(transcript: "", phase: .starting)
            FieldDropdownDictation(transcript: "Remind me to call the bank tomorrow", phase: .listening)
            FieldDropdownDictation(transcript: "Remind me to call the bank tomorrow", phase: .committing)
        }
        .frame(width: 340)
        .padding(24)
    }
    .frame(height: 700)
    .background(LinearGradient(colors: [.blue.opacity(0.25), .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
}
#endif
