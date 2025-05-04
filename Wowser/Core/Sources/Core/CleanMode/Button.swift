import SwiftUI

//CleanModeStatusButton(webContentID: webContentID)

struct CleanModeStatusButton: View {
    var webContentID: ID<WebContent>
    @State private var status = CleanModeButtonStatus.readerUnavail
    
    var body: some View {
        BorderedToolbarButton(label: status.style.title, filled: status.style.active) {
            status.toggle(paneID: webContentID)
        }
        .disabled(status.disabled)
        .onReceive(CleanModeStore.shared.cleanModeSnapshotForPane(id: webContentID).map({ $0.buttonStatus }).removeDuplicates(), perform: { self.status = $0 })
    }
}

private enum CleanModeButtonStatus: Equatable {
    case readerOn
    case cleanOn
    case cleanOff
    case readerMayBeAvail
    case readerUnavail
    
    var style: (title: String, active: Bool) {
        switch self {
        case .readerOn:
            return ("Clean", true)
        case .cleanOn:
            return ("Clean", true)
        case .cleanOff:
            return ("Clean", false)
        case .readerMayBeAvail:
            return ("Clean", false)
        case .readerUnavail:
            return ("Clean", false)
        }
    }
    
    var disabled: Bool {
        switch self {
        case .readerOn, .cleanOn, .cleanOff, .readerMayBeAvail: return false
        case .readerUnavail: return true
        }
    }
    
    func toggle(paneID: ID<WebContent>) {
        guard let info = BrowserStore.shared.model.pane(forId: paneID)?.info else { return }
        guard let url = info.committedURL else { return }
        switch self {
        case .readerOn:
            // turn reader off
            CleanModeStore.shared.model.setReaderModeEnabled(false, onURL: url)
        case .cleanOn:
            // turn clean off
            CleanModeStore.shared.model.setStylingEnabled(false, onURL: url)
        case .cleanOff:
            // clean on
            CleanModeStore.shared.model.setStylingEnabled(true, onURL: url)
        case .readerMayBeAvail:
            // turn reader on
            CleanModeStore.shared.model.setReaderModeEnabled(true, onURL: url)
        case .readerUnavail:
            () // no op
        }
    }
}

private extension CleanModeSnapshotForPane {
    var buttonStatus: CleanModeButtonStatus {
        if !hasURL {
            return .readerUnavail
        }
        if wantsReader && readerReady {
            return .readerOn
        }
        if wantsReader && !readerReady {
            return .readerUnavail
        }
        if wantsCSS != nil {
            return .cleanOn
        }
        if cssAvail {
            return .cleanOff
        }
        return .readerMayBeAvail
    }
}
