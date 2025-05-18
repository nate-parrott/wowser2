#if os(iOS)
import UIKit
import SwiftUI
import Combine

public struct InputTextField: UIViewRepresentable {
    @Binding var text: String
    var options: InputTextFieldOptions
    var focusDate: Date?
    var onEvent: (TextFieldEvent) -> Void
    var contentSize: Binding<CGSize>?
    
    public init(text: Binding<String>, options: InputTextFieldOptions, focusDate: Date? = nil, onEvent: @escaping (TextFieldEvent) -> Void, contentSize: Binding<CGSize>? = nil) {
        _text = text
        self.options = options
        self.focusDate = focusDate
        self.onEvent = onEvent
        self.contentSize = contentSize
    }

    public func makeUIView(context: Context) -> UINSView { _InputTextFieldView() }

    public func updateUIView(_ uiView: UINSView, context: Context) {
        let uiView = uiView as! _InputTextFieldView
        uiView.text = $text
        uiView.options = options
        uiView.onEvent = onEvent
        uiView.focusDate = focusDate
        uiView.contentSize = contentSize
    }
}

class _InputTextFieldView: UIView, UITextViewDelegate {
    var onEvent: ((TextFieldEvent) -> Void)?
    var text = Binding<String>(get: { "" }, set: { _ in }) {
        didSet {
            if text.wrappedValue != textView.text {
                textView.text = text.wrappedValue
                contentSizeMayHaveChanged()
            }
        }
    }
    var focusDate: Date? {
        didSet {
            if focusDate != oldValue {
                if focusDate != nil {
                    DispatchQueue.main.async {
                        self.textView.becomeFirstResponder()
                        if self.options.selectAllOnFocus {
                            self.textView.selectAll(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                // If text field is already short (ie user is typing) dont
                                if self.textView.text.count > 3 {
                                    self.textView.selectAll(nil)
                                }
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        if self.textView.isFirstResponder {
                            self.textView.resignFirstResponder()
                        }
                    }
                }
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

    private let textView = UITextView()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setup() {
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.allowsEditingTextAttributes = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        
        // Default textview configuration
        textView.isScrollEnabled = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(textView)
        
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    
    var options: InputTextFieldOptions = InputTextFieldOptions(placeholder: "") {
        didSet {
            guard options != oldValue else { return }
            // update:
            textView.font = options.font
            textView.textColor = options.color
            textView.tintColor = options.color
            
            // Setup placeholder - UITextView doesn't have a built-in placeholder
            // We'll need to handle this manually by checking for empty text
            
            // Apply insets
            textView.textContainerInset = UIEdgeInsets(
                top: options.insets.height,
                left: options.insets.width,
                bottom: options.insets.height,
                right: options.insets.width
            )
            
            // Apply line limit if specified
            if let lineLimit = options.lineLimit {
                textView.isScrollEnabled = lineLimit > 1
                if lineLimit == 1 {
                    textView.textContainer.maximumNumberOfLines = 1
                } else {
                    textView.textContainer.maximumNumberOfLines = lineLimit
                }
            } else {
                textView.isScrollEnabled = true
                textView.textContainer.maximumNumberOfLines = 0
            }
            
            contentSizeMayHaveChanged()
            updatePlaceholder()
        }
    }
    
    // Handle placeholder manually since UITextView doesn't have built-in placeholder
    private let placeholderLabel = UILabel()
    
    private func updatePlaceholder() {
        if placeholderLabel.superview == nil {
            addSubview(placeholderLabel)
        }
        
        placeholderLabel.font = options.font
        placeholderLabel.text = options.placeholder
        placeholderLabel.textColor = options.placeholderColor ?? options.color.withAlphaComponent(0.5)
        placeholderLabel.numberOfLines = options.lineLimit ?? 0
        
        // Set insets to match textView
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = textView.bounds.inset(by: textView.textContainerInset)
    }
    
    private var focusSubscriptions = Set<AnyCancellable>()
    
    private func contentSizeMayHaveChanged() {
        // Calculate the content size based on the text and options
        let size = textView.sizeThatFits(CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude))
        
        let minHeight = options.font.pointSize
        let calculatedSize = CGSize(
            width: size.width,
            height: max(size.height, minHeight)
        )
        
        if let contentSize, contentSize.wrappedValue != calculatedSize {
            DispatchQueue.main.async {
                contentSize.wrappedValue = calculatedSize
            }
        }
    }
    
    // MARK: - UITextViewDelegate
    
    func textViewDidChange(_ textView: UITextView) {
        text.wrappedValue = textView.text
        contentSizeMayHaveChanged()
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
    
    func textViewDidBeginEditing(_ textView: UITextView) {
        onEvent?(.focus)
    }
    
    func textViewDidEndEditing(_ textView: UITextView) {
        onEvent?(.blur)
    }
    
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Check for paste operations
        if !text.isEmpty {
            // First check large pastes
            if let threshold = options.largePasteThreshold,
               text.count > threshold {
                if let pb = UIPasteboard.general.string, text == pb {
                    onEvent?(.largePaste(text))
                    return false
                }
            }
            
            // Then check for URLs in shorter pastes
            if let pb = UIPasteboard.general.string,
               text == pb,
               isProbablyURL(text),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                onEvent?(.didPasteURL(url))
            }
        }
        
        // Handle special keys
        if text == "\n" {
            let flags = UIKeyModifierFlags(rawValue: 0) // No easy way to get modifiers in UIKit
            // If cmd required but not pressed, insert newline
            if options.requireCmdEnter {
                return true
            }
            // Otherwise send event
            onEvent?(.key(.enter))
            contentSizeMayHaveChanged()
            return false
        }
        
        // Handle backspace on empty field
        if text.isEmpty && range.length == 1 && range.location == 0 && textView.text.isEmpty {
            onEvent?(.backspaceOnEmptyField)
            return false
        }
        
        return true
    }
    
    private func isProbablyURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) &&
               !trimmed.contains(" ") &&
               trimmed.contains(".")
    }
    
    // iOS support for arrow keys when using hardware keyboard
    override var canBecomeFirstResponder: Bool { true }
    
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else {
            super.pressesBegan(presses, with: event)
            return
        }
        
        if options.wantsUpDownArrowEvents {
            if key.keyCode == .keyboardUpArrow {
                onEvent?(.key(.upArrow))
                return
            } else if key.keyCode == .keyboardDownArrow {
                onEvent?(.key(.downArrow))
                return
            }
        }
        
        if key.keyCode == .keyboardEscape {
            onEvent?(.key(.escape))
            return
        }
        
        super.pressesBegan(presses, with: event)
    }
}

extension UIColor {
    func withAlphaComponentSafe(_ alpha: CGFloat) -> UIColor {
        return self.withAlphaComponent(alpha)
    }
}
#endif
