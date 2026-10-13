import SwiftUI
//
//  OnboardingKit.swift
//  Core
//
//  Created by Nate Parrott on 10/4/26.
//

/*
 Flow:
 
 Welcome to Wowser
 The browser that'll make you say "wow, the perfect place for all my stuff!"
 Pick a theme to get started
 [wallpapers, with Unsplash credit under the selected one] [plain swatches]
 [Get started]
 
 -----
 
 Transfer logins and history, so you don't have to log in to everything again
 
 # Chrome
 [Profile 1 - usage amt] [Import]
 [Profile 2 - usage amt] [Import]
 [Profile 3 - usage amt] [Import]
 // -- etc --
 Imports cookies, logins, passwords into autofill [i] // allows checking/unchecking
 
 # Safari
 [Drop passwords exported]
 
 [Skip] // or 'done' if you pick some
 
 // Creates one space + profile per import; pins top sites as faves
 
 -----
 
 Set as default browser?
 
 [Set as Default] [Not yet]
 
 -----
 
 Connect your AI
 > Use your existing AI subscription from the browser, for answering quick questions or performing tasks.
 > We'll add the Wowser MCP, which lets it do anything in the browser that you can do.
 
 [Use Claude]
 // Subtext: uses Claude for agent chats and adds the Wowser MCP, so Claude can access the browser.
 [Use Codex] (disabled)
 // Subtext: unavailable
 
 [Skip for now]
 
 -----
 
 Limitations:
 
 - Very experimental
 - No passkeys
 - Some sites don't work
 - Not security-tested
 
 [I understand]
 
 -----
 
 Enable other goodies
 
 [x] Ad blocker
 [x] Auto dark mode on websites
 [ ] Memory -- let your AI full-text search your browsing activity
 
 -----
 
 Make spaces for your projects
 
 [Icon] [Title] [Folder] // repeat once for each project added; maybe suggest some using ai from history?
 [Text field: placeholder 'Finding an apartment'] [+ Folder] [Add]
 [Add folder]
 // Subtitle: Good for coding projects
 
 -----
 
 Learn some neat tricks (NB: no need to track whetehr these work)
 
 [ ] Option-click a link to open in split ([try it](http://example.com))
 [ ] Click in the top bar (CMD-L) and ask a question about this page (try it!)
 [ ] Swipe down with three fingers to cycle thru recent tabs (or press CMD-E) (try it!)
 [ ] Drag an image into the sidebar to set it as a space background (try it -- provides image thumbnail from preset unsplash images)
 
 */

// Components: Button, Screen, Toggle, Well, FeatheredScroll, Radio

struct OnboardingScreen<C: View, Footer: View>: View {
    @ViewBuilder var content: () -> C
    @ViewBuilder var footer: () -> Footer
    
    var mainMaxWidth: CGFloat = 700
    var padding: CGFloat {
        if viewport.width < 500 || viewport.height < 500 { return 20 }
        if viewport.width >= 1100 && viewport.height >= 700 { return 96 }
        return 60
    }
    private var smallViewport: Bool { padding <= 20 }
    
    /// Set by `OnboardingFlow` on every step but the first.
    @Environment(\.onboardingBack) private var back
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewport = CGSize(width: 800, height: 800)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                content()
                    .padding(padding)
                    .frame(maxWidth: mainMaxWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
            }
            .modifier(FeatherTopAndBottom(featherHeight: padding * 0.8))
            
            // Buttons are left-aligned under the content column, wrapping
            // rather than widening the screen past a narrow viewport.
            OnboardingFlowLayout(spacing: 12) {
                if let back {
                    Button("Back", action: back)
                        .buttonStyle(OnboardingButtonStyle(primary: false))
                }
                footer()
            }
            .frame(maxWidth: mainMaxWidth - padding * 2, alignment: .leading)
            .frame(maxWidth: .infinity)
            .buttonStyle(OnboardingButtonStyle(primary: true))
            .padding(.horizontal, padding)
            .padding(.bottom, padding)
        }
        .controlSize(smallViewport ? .regular : .extraLarge)
        .measureSize({ self.viewport = $0 })
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0), Color.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(colorScheme == .dark ? 0.05 : 0.09)
        }
    }
}

extension EnvironmentValues {
    /// Goes back one onboarding step; nil on the first step.
    @Entry var onboardingBack: (() -> Void)? = nil
}

extension AnyTransition {
    /// Screen-to-screen transition: the next screen pushes in from the
    /// trailing edge. Apply to each screen (keyed with `.id(step)`) and change
    /// the step inside `withAnimation`.
    static var onboardingScreen: AnyTransition { .push(from: .trailing) }
}

/// Lays out subviews left to right, wrapping onto new lines.
struct OnboardingFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Big title + optional explanation at the top of a screen.
struct OnboardingHeader: View {
    var title: String
    /// A `Text` so it can inline images (e.g. `Image.wowie`).
    var subtitle: Text?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle.map { Text($0) }
    }

    init(title: String, subtitle: Text) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                subtitle
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FeatherTopAndBottom: ViewModifier {
    var featherHeight: CGFloat = 20
    
    @State private var contentHeight: CGFloat = 100
    
    func body(content: Content) -> some View {
        let x = featherHeight / max(1, contentHeight)
        content.mask {
            LinearGradient(stops: [
                Gradient.Stop(color: Color.clear, location: 0),
                Gradient.Stop(color: Color.black, location: x),
                Gradient.Stop(color: Color.black, location: 1 - x),
                Gradient.Stop(color: Color.clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .measureSize({ self.contentHeight = $0.height })
    }
}

/// A rounded card of cells separated by dividers. Each direct subview of
/// `content` (including each element a `ForEach` emits) becomes one cell.
struct OnboardingSection<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    @Environment(\.colorScheme) private var colorScheme

    /// Brighter than the page behind it in both appearances.
    private var cardFill: Color {
        colorScheme == .dark ? Color(white: 0.2) : Color.white
    }

    var body: some View {
        VStack(alignment: .leading) {
            if let title {
                Text(title)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews.indices, id: \.self) { i in
                        ZStack(alignment: .leading) {
                            Color.clear.frame(height: 50)
                            subviews[i]
                        }
                        if i < subviews.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
            .controlSize(.regular) // cells use normal-size controls even when the screen's footer is extra large
            .frame(maxWidth: 500, alignment: .leading)
            .clipShape(shape)
            .background {
                shape.fill(cardFill)
                    .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 2)
            }
        }
    }
}

extension View {
    /// Standard insets for a cell inside an `OnboardingSection`.
    func onboardingCell() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title + secondary subtitle, as used in onboarding cells.
struct OnboardingCellLabel: View {
    var title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OnboardingRadioOption<Value: Hashable>: Identifiable {
    var value: Value
    var title: String
    var subtitle: String? = nil
    var disabled = false

    var id: Value { value }
}

/// A section with one radio cell per option.
struct OnboardingRadioGroup<Value: Hashable>: View {
    var title: String? = nil
    var options: [OnboardingRadioOption<Value>]
    @Binding var selection: Value?

    var body: some View {
        OnboardingSection(title: title) {
            ForEach(options) { option in
                OnboardingRadioToggleContentCell(
                    title: option.title,
                    subtitle: option.subtitle,
                    isSelected: selection == option.value,
                    disabled: option.disabled,
                    select: { selection = option.value }
                )
            }
        }
    }
}

/// A single cell, made to be embedded in an onboarding section cell
struct OnboardingRadioToggleContentCell: View {
    var title: String
    var subtitle: String? = nil
    var isSelected: Bool
    var disabled = false
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                OnboardingCellLabel(title: title, subtitle: subtitle)
                Spacer(minLength: 0)
            }
            .onboardingCell()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

/// A single cell, made to be embedded in an onboarding section cell: a
/// checkbox with a title/subtitle, plus an optional trailing accessory.
struct OnboardingBinaryToggleContentCell<Accessory: View>: View {
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isOn) {
                OnboardingCellLabel(title: title, subtitle: subtitle)
                    .padding(.leading, 4)
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            Spacer(minLength: 0)
            accessory
        }
        .onboardingCell()
    }
}

extension OnboardingBinaryToggleContentCell where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(title: title, subtitle: subtitle, isOn: isOn, accessory: { EmptyView() })
    }
}

/// Large glass button. Primary buttons are tinted with the accent color;
/// secondary ones are plain glass. Size follows the environment's control size.
struct OnboardingButtonStyle: ButtonStyle {
    var primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        OnboardingButtonBody(configuration: configuration, primary: primary)
    }
}

private struct OnboardingButtonBody: View {
    var configuration: ButtonStyleConfiguration
    var primary: Bool
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    private var large: Bool { controlSize == .large || controlSize == .extraLarge }

    var body: some View {
        configuration.label
            .font(large ? .title3.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, large ? 26 : 16)
            .padding(.vertical, large ? 12 : 7)
            .frame(minWidth: large ? 130 : 80)
            .contentShape(Capsule())
            .glassEffect(primary ? .regular.tint(.accentColor) : .regular, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

private struct OnboardingDemoView: View {
    @State private var choice: String? = "a"
    @State private var on = true

    var body: some View {
        OnboardingScreen(content: {
            VStack(alignment: .leading, spacing: 24) {
                OnboardingHeader(title: "Hey!", subtitle: "A demo of the onboarding kit.")
                OnboardingRadioGroup(options: [
                    OnboardingRadioOption(value: "a", title: "Option A", subtitle: "The first one"),
                    OnboardingRadioOption(value: "b", title: "Option B", disabled: true),
                ], selection: $choice)
                OnboardingSection(title: "Toggles") {
                    OnboardingBinaryToggleContentCell(title: "Something", subtitle: "Does a thing", isOn: $on)
                    OnboardingBinaryToggleContentCell(title: "Another", isOn: $on) {
                        Button("Try it") {}
                    }
                }
            }
        }, footer: {
            Button("Continue") {}
        })
    }
}

#Preview {
    OnboardingDemoView()
        .environment(\.onboardingBack, {})
}
