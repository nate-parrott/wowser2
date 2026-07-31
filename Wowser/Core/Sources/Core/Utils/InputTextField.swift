import SwiftUI
import Combine

public enum TextFieldEvent {
    public enum Key: Equatable {
        case enter
        case upArrow
        case downArrow
        case escape
    }

    case key(Key)
    case focus
    case blur
    case largePaste(String)
    case didPasteURL(URL)
    case backspaceOnEmptyField
}

public struct InputTextFieldOptions: Equatable {
    var placeholder: String
    var font: UINSFont = UINSFont.systemFont(ofSize: 14)
    var color: UINSColor = UINSColor.textColor
    var insets = CGSize(width: 0, height: 0)
    var placeholderColor: UINSColor? = nil
    var requireCmdEnter: Bool = false
    var wantsUpDownArrowEvents: Bool = true
    var largePasteThreshold: Int? = nil
    var selectAllOnFocus: Bool = false
    var lineLimit: Int? = nil
    var disableFindReplace: Bool = false
    
    var effectivePlaceholderColor: UINSColor {
        return placeholderColor ?? color.withAlphaComponentSafe(0.5)
    }

    var attributedPlaceholder: NSAttributedString {
        let str = NSMutableAttributedString(string: placeholder, attributes: [
            .foregroundColor: effectivePlaceholderColor,
            .font: font,
        ])
        if lineLimit == 1 {
            let para = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
            para.lineBreakMode = .byTruncatingTail
            str.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: str.length))
        }
        return str
    }
    
    public init(placeholder: String,
                font: UINSFont = UINSFont.systemFont(ofSize: 14),
                color: UINSColor = UINSColor.textColor,
                insets: CGSize = CGSize(width: 0, height: 0), 
                placeholderColor: UINSColor? = nil, 
                requireCmdEnter: Bool = false, 
                wantsUpDownArrowEvents: Bool = true, 
                largePasteThreshold: Int? = nil, 
                selectAllOnFocus: Bool = false,
                lineLimit: Int? = nil,
                disableFindReplace: Bool = false
    ) {
        self.placeholder = placeholder
        self.font = font
        self.color = color
        self.insets = insets
        self.placeholderColor = placeholderColor
        self.requireCmdEnter = requireCmdEnter
        self.wantsUpDownArrowEvents = wantsUpDownArrowEvents
        self.largePasteThreshold = largePasteThreshold
        self.selectAllOnFocus = selectAllOnFocus
        self.lineLimit = lineLimit
        self.disableFindReplace = disableFindReplace
    }
}
