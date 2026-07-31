#if os(macOS)
import AppKit
import SwiftUI
import Combine

public struct InputTextField: NSViewRepresentable {
    @Binding var text: String
    var options: InputTextFieldOptions
    var focusDate: Date?
    /// If set, focusing routes through `wowser_becomeFirstResponder(asTarget:)`
    /// so the resulting first-responder callback doesn't loop back into
    /// `BrowserState.didFocus`. Required for any text field that participates
    /// in the FocusTarget system (e.g. the omnibox).
    var focusTarget: FocusTarget?
    var onEvent: (TextFieldEvent) -> Void
    var contentSize: Binding<CGSize>?

    public init(text: Binding<String>, options: InputTextFieldOptions, focusDate: Date? = nil, focusTarget: FocusTarget? = nil, onEvent: @escaping (TextFieldEvent) -> Void, contentSize: Binding<CGSize>? = nil) {
        _text = text
        self.options = options
        self.focusDate = focusDate
        self.focusTarget = focusTarget
        self.onEvent = onEvent
        self.contentSize = contentSize
    }

    public func makeNSView(context: Context) -> UINSView { _InputTextFieldView() }

    public func updateNSView(_ nsView: UINSView, context: Context) {
        let nsView = nsView as! _InputTextFieldView
        nsView.text = $text
        nsView.options = options
        nsView.onEvent = onEvent
        nsView.focusTarget = focusTarget
        nsView.focusDate = focusDate
        nsView.contentSize = contentSize
    }
}


class _InputTextFieldView: NSView, NSTextViewDelegate {
    var onEvent: ((TextFieldEvent) -> Void)?
    var text = Binding<String>(get: { "" }, set: { _ in }) {
        didSet {
            if text.wrappedValue != textView.string {
                textView.string = text.wrappedValue
                contentSizeMayHaveChanged()
            }
        }
    }
    var focusTarget: FocusTarget?
    var focusDate: Date? {
        didSet {
            if focusDate != oldValue {
                if focusDate != nil {
                    DispatchQueue.main.async {
                        if let target = self.focusTarget {
                            self.textView.wowser_becomeFirstResponder(asTarget: target)
                        } else {
                            self.window?.makeFirstResponder(self.textView)
                        }
                        if self.options.selectAllOnFocus {
                            self.textView.selectAll(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                // If text field is already short (ie user is typing) dont
                                if self.textView.string.count > 3 {
                                    self.textView.selectAll(nil)
                                }
                            }
                        }
                    }
                }
                // No `else { resignFirstResponder }`: when focus moves elsewhere
                // (e.g. webview), that target's wowser_becomeFirstResponder will
                // take focus from us automatically.
            }
        }
    }
    var contentSize: Binding<CGSize>? {
        didSet {
            DispatchQueue.main.async {
                self.contentSizeMayHaveChanged()
            }
        }
    }

    // multi-line scrolling nstextview
    private let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.delegate = self
        textView.allowsUndo = true
        
        // Default textview configuration
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange(_:)), name: NSText.didChangeNotification, object: textView)
//        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
    }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    var options: InputTextFieldOptions = InputTextFieldOptions(placeholder: "") {
        didSet {
            guard options != oldValue else { return }
            // update:
            textView.font = options.font
            textView.textColor = options.color
            textView.insertionPointColor = options.color
            textView.setValue(options.attributedPlaceholder, forKey: "placeholderAttributedString")
            textView.textContainerInset = options.insets
            
            // Apply line limit if specified
            if let lineLimit = options.lineLimit {
                textView.isVerticallyResizable = lineLimit > 1
//                textView.setUsesFindPanel(lineLimit > 1)
                textView.isHorizontallyResizable = false
                if lineLimit == 1 {
                    textView.textContainer?.maximumNumberOfLines = 1
                    textView.textContainer?.widthTracksTextView = true
                } else {
                    textView.textContainer?.maximumNumberOfLines = lineLimit
                    textView.textContainer?.widthTracksTextView = true
                }
            } else {
                textView.isVerticallyResizable = true
                textView.isHorizontallyResizable = false
                textView.textContainer?.maximumNumberOfLines = 0
                textView.textContainer?.widthTracksTextView = true
            }
            
            // Turn off find/replace?
            if textView.usesFindBar != options.disableFindReplace {
                textView.usesFindBar = !options.disableFindReplace
            }
            if options.disableFindReplace && textView.usesFindPanel {
                textView.usesFindPanel = false
            }
            
            contentSizeMayHaveChanged()
        }
    }

    // override did move to windwo and focus if necessary

    private var focusSubscriptions = Set<AnyCancellable>()
    private var wasFirstResponder = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        focusSubscriptions.removeAll()
        guard let window else { return }

//        if focusDate != nil {
//            window.makeFirstResponder(textView)
//        }

        // KVO the window's first responder to see if it's us. Only report
        // transitions: the publisher fires for every first-responder change in
        // the window (plus once on subscribe), and consumers treat .blur as
        // "the user finished editing" — delivering it when we never had focus
        // makes them commit stale state.
        wasFirstResponder = window.firstResponder === textView
        window.publisher(for: \.firstResponder).sink { [weak self] firstResponder in
            guard let self else { return }
            let isUs = firstResponder === self.textView
            guard isUs != self.wasFirstResponder else { return }
            self.wasFirstResponder = isUs
            self.onEvent?(isUs ? .focus : .blur)
        }.store(in: &focusSubscriptions)

        contentSizeMayHaveChanged()
    }

    private func contentSizeMayHaveChanged() {
        if let textContainer = self.textView.textContainer, let layoutMgr = self.textView.layoutManager {
            let takenSize = layoutMgr.usedRect(for: textContainer).size
            let minHeight = options.font.pointSize
            let size = CGSize(
                width: takenSize.width + options.insets.width * 2,
                height: max(takenSize.height, minHeight) + options.insets.height * 2
            )
            if let contentSize, contentSize.wrappedValue != size {
                DispatchQueue.main.async {
                    contentSize.wrappedValue = size
                }
            }
        }
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        // Check for paste operations
        if let text = text {
            // First check large pastes
            if let threshold = options.largePasteThreshold,
               text.count > threshold,
               !NSEvent.modifierFlags.contains(.shift) {
                if let pb = NSPasteboard.general.string(forType: .string), text == pb {
                    onEvent?(.largePaste(text))
                    return false
                }
            }
            
            // Then check for URLs in shorter pastes
            if let pb = NSPasteboard.general.string(forType: .string),
               text == pb,
               isProbablyURL(text),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                onEvent?(.didPasteURL(url))
            }
        }
        return true
    }
    
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // https://stackoverflow.com/questions/11682939/add-hotkey-to-nstextfield
        if NSEvent.modifierFlags.contains(.command) && NSApp.currentEvent?.keyCode == 0x24, options.requireCmdEnter {
            onEvent?(.key(.enter))
            contentSizeMayHaveChanged()
            return true
        }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let flags = NSEvent.modifierFlags
            // If shift pressed, always insert newline
            if flags.contains(.shift) {
                return false
            }
            // If cmd required but not pressed, insert newline
            if options.requireCmdEnter && !flags.contains(.command) {
                return false
            }
            // Otherwise send event
            onEvent?(.key(.enter))
            contentSizeMayHaveChanged()
            return true
        case #selector(NSResponder.moveUp(_:)):
            if options.wantsUpDownArrowEvents {
                onEvent?(.key(.upArrow))
                return true
            }
            return false
        case #selector(NSResponder.moveDown(_:)):
            if options.wantsUpDownArrowEvents {
                onEvent?(.key(.downArrow))
                return true
            }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            onEvent?(.key(.escape))
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            if textView.selectedRange.length == 0,
                textView.string.isEmpty || textView.selectedRange.location == 0 {
                onEvent?(.backspaceOnEmptyField)
                return true
            }
            return false
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        text.wrappedValue = textView.string
        contentSizeMayHaveChanged()
    }

    override var mouseDownCanMoveWindow: Bool { true }
    
    private func isProbablyURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) &&
               !trimmed.contains(" ") &&
               trimmed.contains(".")
    }

    // We need to provide our own undo mgr to avoid propagating undos to the document level and triggering "Edited" UI on the windows
    let undoMgr = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? {
        undoMgr
    }
}
#endif

