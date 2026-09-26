#if os(macOS)
import SwiftUI

// Previews for the field dropdown in every state, each hanging off a mock
// page text field so placement is exercised too. Rows respond to hover and
// click; arrow keys aren't wired (in the app those come from the webview).

/// A fake page with one text field; `dropdown` is placed under it exactly as
/// `FieldDropdownOverlay` would place it.
private struct MockFieldPage<Dropdown: View>: View {
    var label: String
    var value: String
    var fieldRect = CGRect(x: 40, y: 70, width: 300, height: 30)
    var estimatedHeight: CGFloat
    var outline: Bool = false
    @ViewBuilder var dropdown: (FieldDropdownPlacement) -> Dropdown

    var body: some View {
        GeometryReader { geo in
            let placement = FieldDropdownPlacement(field: fieldRect, container: geo.size, estimatedHeight: estimatedHeight)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(white: 0.97), Color(white: 0.9)], startPoint: .top, endPoint: .bottom)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black.opacity(0.7))
                    .offset(x: fieldRect.minX, y: fieldRect.minY - 20)
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.25)))
                    .overlay(alignment: .leading) {
                        Text(value).font(.system(size: 13)).foregroundStyle(.black).padding(.horizontal, 8)
                    }
                    .frame(width: fieldRect.width, height: fieldRect.height)
                    .offset(x: fieldRect.minX, y: fieldRect.minY)
                if outline {
                    DictationOutline(active: true)
                        .frame(width: fieldRect.width + 8, height: fieldRect.height + 8)
                        .offset(x: fieldRect.minX - 4, y: fieldRect.minY - 4)
                }
                dropdown(placement)
                    .frame(width: placement.width)
                    .offset(x: placement.x, y: placement.y)
            }
        }
        .frame(width: 520, height: 360)
    }
}

// MARK: - Sample data

private enum Samples {
    static let logins: [FieldDropdownSuggestionList.Item] = [
        .init(id: "1", systemImage: "key.fill", title: "alice@example.com", subtitle: "example.com · used today"),
        .init(id: "2", systemImage: "key.fill", title: "alice.work@example.com", subtitle: "accounts.example.com"),
        .init(id: "3", systemImage: "key.fill", title: "a-very-long-username-that-needs-truncating@subdomain.example.com", subtitle: "example.com"),
    ]
    static let identity: [FieldDropdownSuggestionList.Item] = [
        .init(id: "n", systemImage: "person.fill", title: "Alice Liddell", subtitle: "Fills first & last name"),
        .init(id: "e", systemImage: "envelope.fill", title: "alice@example.com", subtitle: nil),
        .init(id: "a", systemImage: "house.fill", title: "1 Rabbit Hole Ln", subtitle: "Oxford, OX1 1AA, United Kingdom"),
    ]
    static let countries: [FieldDropdownOptionList.Option] = [
        "Afghanistan", "Albania", "Algeria", "Andorra", "Angola", "Argentina", "Armenia", "Australia", "Austria",
        "Bahamas", "Bangladesh", "Belgium", "Brazil", "Canada", "Chile", "China", "Denmark", "Egypt", "France",
        "Germany", "Ghana", "Greece", "India", "Ireland", "Italy", "Japan", "Kenya", "Mexico", "Netherlands",
        "New Zealand", "Norway", "Peru", "Portugal", "Spain", "Sweden", "United Kingdom", "United States",
    ].enumerated().map { .init(id: $0.offset, label: $0.element, group: nil, disabled: false) }
    static let grouped: [FieldDropdownOptionList.Option] = [
        .init(id: 0, label: "Standard (5–7 days)", group: "Ground", disabled: false),
        .init(id: 1, label: "Economy (7–10 days)", group: "Ground", disabled: false),
        .init(id: 2, label: "Express (2 days)", group: "Air", disabled: false),
        .init(id: 3, label: "Overnight — unavailable", group: "Air", disabled: true),
        .init(id: 4, label: "Store pickup", group: "Other", disabled: false),
    ]
}

// MARK: - Interactive wrappers

private struct SuggestionsPreview: View {
    var label: String
    var value: String
    var items: [FieldDropdownSuggestionList.Item]
    var trailing: String? = "lock.fill"
    @State private var highlighted = 0
    @State private var chosen: String?

    var body: some View {
        MockFieldPage(label: label, value: chosen ?? value, estimatedHeight: FieldDropdownSuggestionList.estimatedHeight(rows: items.count)) { _ in
            FieldDropdownSuggestionList(
                items: items,
                highlighted: highlighted,
                trailingSystemImage: trailing,
                onHover: { highlighted = $0 },
                onChoose: { chosen = items[$0].title }
            )
        }
    }
}

private struct OptionsPreview: View {
    var label: String
    var filter: String
    var options: [FieldDropdownOptionList.Option]
    @State private var highlighted = 0
    @State private var selected: Int?

    var body: some View {
        let filtered = filter.isEmpty ? options : options.filter { $0.label.lowercased().contains(filter.lowercased()) }
        MockFieldPage(label: label, value: selected.flatMap { id in options.first { $0.id == id }?.label } ?? "Choose…", estimatedHeight: FieldDropdownOptionList.estimatedHeight(rows: filtered.count)) { placement in
            FieldDropdownOptionList(
                filter: filter,
                options: filtered,
                highlighted: highlighted,
                selectedID: selected,
                maxListHeight: placement.listHeight(rowHeight: FieldDropdownOptionList.rowHeight),
                onHover: { highlighted = $0 },
                onChoose: { selected = $0.id }
            )
        }
    }
}

private struct DictationPreview: View {
    var value: String
    var transcript: String
    var phase: DictationController.Phase

    var body: some View {
        MockFieldPage(label: "Message", value: value, estimatedHeight: FieldDropdownDictation.estimatedHeight, outline: true) { _ in
            FieldDropdownDictation(transcript: transcript, phase: phase)
        }
    }
}

// MARK: - Previews

#Preview("Autofill · logins") {
    SuggestionsPreview(label: "Email", value: "", items: Samples.logins)
}

#Preview("Autofill · identity") {
    SuggestionsPreview(label: "Full name", value: "Al", items: Samples.identity, trailing: nil)
}

#Preview("Autofill · single") {
    SuggestionsPreview(label: "Username", value: "", items: Array(Samples.logins.prefix(1)))
}

#Preview("Select · countries") {
    OptionsPreview(label: "Country", filter: "", options: Samples.countries)
}

#Preview("Select · filtered") {
    OptionsPreview(label: "Country", filter: "united", options: Samples.countries)
}

#Preview("Select · no matches") {
    OptionsPreview(label: "Country", filter: "zzz", options: Samples.countries)
}

#Preview("Select · optgroups + disabled") {
    OptionsPreview(label: "Shipping", filter: "", options: Samples.grouped)
}

#Preview("Dictation · starting") {
    DictationPreview(value: "", transcript: "", phase: .starting)
}

#Preview("Dictation · listening, empty") {
    DictationPreview(value: "", transcript: "", phase: .listening)
}

#Preview("Dictation · listening") {
    DictationPreview(value: "Hi team,", transcript: "Thanks for the update. I'll take a look at the autofill playground this afternoon", phase: .listening)
}

#Preview("Dictation · long transcript") {
    DictationPreview(value: "", transcript: String(repeating: "This is a very long dictated paragraph that keeps going. ", count: 8), phase: .listening)
}

#Preview("Dictation · committing") {
    DictationPreview(value: "", transcript: "Book a table for two at seven", phase: .committing)
}

#Preview("Placement · field near bottom") {
    MockFieldPage(label: "Password", value: "••••••", fieldRect: CGRect(x: 180, y: 300, width: 220, height: 30), estimatedHeight: FieldDropdownSuggestionList.estimatedHeight(rows: 3)) { _ in
        FieldDropdownSuggestionList(items: Samples.logins, highlighted: 1)
    }
}

#Preview("Gallery") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            FieldDropdownSuggestionList(items: Samples.logins, highlighted: 0)
            FieldDropdownSuggestionList(items: Samples.identity, highlighted: 2, trailingSystemImage: nil)
            FieldDropdownOptionList(filter: "an", options: Samples.countries.filter { $0.label.lowercased().contains("an") }, highlighted: 1, selectedID: 3, maxListHeight: 180)
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
