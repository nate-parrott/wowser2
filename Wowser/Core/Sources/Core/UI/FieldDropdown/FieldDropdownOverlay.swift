#if os(macOS)
import SwiftUI

/// Sits over a pane's webview (see `WrappedWebView`) and owns the single
/// dropdown slot under the page's focused field. In priority order:
///
/// 1. live dictation into a field of this page (`DictationController`),
/// 2. the searchable `<select>` menu (`AutofillSession.selectMenu`),
/// 3. autofill suggestions (`AutofillSession.menu`).
///
/// Everything outside the dropdown passes clicks through to the page. The
/// webview keeps first responder; keys reach the menus via
/// `AutofillSession.handleKeyDown` and dictation's own key monitor.
struct FieldDropdownOverlay: View {
    var webContent: WebContent

    @ObservedObject private var dictation = DictationController.shared

    /// The field being dictated into on this page, if any.
    private var dictationField: WebContent.Info.FocusedEditable? {
        guard dictation.isActive, let t = dictation.target, case .webField(let pane, let field) = t, pane == webContent.id else { return nil }
        return field
    }

    var body: some View {
        GeometryReader { geo in
            let zoom = webContent.wkWebview?.pageZoom ?? 1
            ZStack(alignment: .topLeading) {
                if let field = dictationField {
                    let placement = FieldDropdownPlacement(field: field.zoomed(zoom), container: geo.size, estimatedHeight: FieldDropdownDictation.estimatedHeight)
                    FieldDropdownDictation(transcript: dictation.transcript, phase: dictation.phase)
                        .frame(width: placement.width)
                        .offset(x: placement.x, y: placement.y)
                        .allowsHitTesting(false)
                } else if let session = webContent.autofill {
                    AutofillDropdowns(session: session, zoom: zoom, container: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

/// The autofill session's two menus, placed under their fields.
private struct AutofillDropdowns: View {
    @ObservedObject var session: AutofillSession
    var zoom: CGFloat
    var container: CGSize

    var body: some View {
        if let open = session.selectMenu {
            let options = open.filteredOptions
            let placement = FieldDropdownPlacement(field: open.anchor.zoomed(zoom), container: container, estimatedHeight: FieldDropdownOptionList.estimatedHeight(rows: options.count))
            FieldDropdownOptionList(
                filter: open.filter,
                options: options.map { .init(id: $0.index, label: $0.label, group: $0.group, disabled: $0.disabled) },
                highlighted: open.highlighted,
                selectedID: open.info.selectedIndex,
                maxListHeight: placement.listHeight(rowHeight: FieldDropdownOptionList.rowHeight),
                onHover: { session.highlightSelectOption($0) },
                onChoose: { choice in
                    if let o = options.first(where: { $0.index == choice.id }) { session.chooseSelectOption(o) }
                }
            )
            .frame(width: placement.width)
            .offset(x: placement.x, y: placement.y)
            .id("select-\(open.info.field.signature)")
        } else if let menu = session.menu, let rect = menu.field.rect {
            let placement = FieldDropdownPlacement(field: rect.zoomed(zoom), container: container, estimatedHeight: FieldDropdownSuggestionList.estimatedHeight(rows: menu.suggestions.count))
            FieldDropdownSuggestionList(
                items: menu.suggestions.map { .init(id: $0.id, systemImage: $0.systemImage, title: $0.title, subtitle: $0.subtitle) },
                highlighted: menu.highlighted,
                onHover: { session.highlight($0) },
                onChoose: { index in
                    if let s = menu.suggestions[safe: index] { Task { await session.accept(s) } }
                }
            )
            .frame(width: placement.width)
            .offset(x: placement.x, y: placement.y)
            .id(menu.field.signature)
        }
    }
}
#endif
