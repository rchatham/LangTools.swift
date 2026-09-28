import Foundation

public struct Text: View, PrimitiveView {
    private var text: String?
    
    private var _attributedText: Any?
    
    @available(macOS 12, *)
    private var attributedText: AttributedString? { _attributedText as? AttributedString }
    
    @Environment(\.foregroundColor) private var foregroundColor: Color
    @Environment(\.bold) private var bold: Bool
    @Environment(\.italic) private var italic: Bool
    @Environment(\.underline) private var underline: Bool
    @Environment(\.strikethrough) private var strikethrough: Bool
    
    public init(_ text: String) {
        self.text = text
    }
    
    @available(macOS 12, *)
    public init(_ attributedText: AttributedString) {
        self._attributedText = attributedText
    }
    
    static var size: Int? { 1 }
    
    func buildNode(_ node: Node) {
        setupEnvironmentProperties(node: node)
        node.control = TextControl(
            text: text,
            attributedText: _attributedText,
            foregroundColor: foregroundColor,
            bold: bold,
            italic: italic,
            underline: underline,
            strikethrough: strikethrough
        )
    }
    
    func updateNode(_ node: Node) {
        setupEnvironmentProperties(node: node)
        node.view = self
        let control = node.control as! TextControl
        control.text = text
        control._attributedText = _attributedText
        control.foregroundColor = foregroundColor
        control.bold = bold
        control.italic = italic
        control.underline = underline
        control.strikethrough = strikethrough
        control.invalidateWrap()
        control.layer.invalidate()
    }
    
    private class TextControl: Control {
        var text: String?
        
        var _attributedText: Any?
        
        @available(macOS 12, *)
        var attributedText: AttributedString? { _attributedText as? AttributedString }
        
        var foregroundColor: Color
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var strikethrough: Bool
        
        init(
            text: String?,
            attributedText: Any?,
            foregroundColor: Color,
            bold: Bool,
            italic: Bool,
            underline: Bool,
            strikethrough: Bool
        ) {
            self.text = text
            self._attributedText = attributedText
            self.foregroundColor = foregroundColor
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.strikethrough = strikethrough
        }
        
        override func size(proposedSize: Size) -> Size {
            let count = Extended(characterCount)
            // Wrap when a finite width is proposed (scroll views, frames and
            // stacks propose the available width). Zero or infinite proposals
            // keep the intrinsic single-line size.
            let width = proposedSize.width
            if width != .infinity, width != -.infinity, width > 0, count > width {
                let rows = Extended((count.intValue + width.intValue - 1) / width.intValue)
                return Size(width: width, height: rows)
            }
            return Size(width: count, height: 1)
        }

        /// Row layout for the last wrapped width: (character start, length)
        /// pairs indexing into the text.
        private var wrapWidth: Extended = -1
        private var wrappedRows: [(start: Int, length: Int)] = []

        /// Forces re-wrapping when the text content changes.
        func invalidateWrap() {
            wrapWidth = -1
            wrappedRows = []
        }

        private var characters: [Character] {
            if #available(macOS 12, *), let attributedText {
                return Array(attributedText.characters)
            }
            return Array(text ?? "")
        }

        private func prepareRows(width: Extended) {
            guard wrapWidth != width else { return }
            wrapWidth = width
            let chars = characters
            let count = chars.count
            let intWidth = max(1, width.intValue)
            var rows: [(start: Int, length: Int)] = []
            var start = 0
            while start < count {
                var length = min(intWidth, count - start)
                if start + length < count {
                    // Prefer breaking at a word boundary within the row (keeping
                    // at least half the width) so prose stays readable.
                    let window = chars[start ..< (start + length)]
                    if let lastSpace = window.lastIndex(where: { $0 == " " }) {
                        let offset = lastSpace - window.startIndex
                        if offset >= length / 2 {
                            length = offset + 1
                        }
                    }
                }
                rows.append((start, length))
                start += length
            }
            wrappedRows = rows
        }

        override func layout(size: Size) {
            super.layout(size: size)
            prepareRows(width: size.width)
            // Match the layer height to the wrapped row count in case the
            // parent laid us out at a height measured with a different width.
            layer.frame.size.height = Extended(max(1, wrappedRows.count))
        }

        override func cell(at position: Position) -> Cell? {
            prepareRows(width: layer.frame.size.width)
            let row = position.line.intValue
            guard row < wrappedRows.count else { return nil }
            let column = position.column.intValue
            guard column < wrappedRows[row].length else { return .init(char: " ") }
            let characterIndex = wrappedRows[row].start + column
            if #available(macOS 12, *), let attributedText {
                let i = attributedText.characters.index(attributedText.characters.startIndex, offsetBy: characterIndex)
                let char = attributedText[i ..< attributedText.characters.index(after: i)]
                let cellAttributes = CellAttributes(
                    bold: char.bold ?? bold,
                    italic: char.italic ?? italic,
                    underline: char.underline ?? underline,
                    strikethrough: char.strikethrough ?? strikethrough,
                    inverted: char.inverted ?? false
                )
                return Cell(
                    char: char.characters[char.startIndex],
                    foregroundColor: char.foregroundColor ?? foregroundColor,
                    backgroundColor: char.backgroundColor,
                    attributes: cellAttributes
                )
            }
            if let text {
                let cellAttributes = CellAttributes(
                    bold: bold,
                    italic: italic,
                    underline: underline,
                    strikethrough: strikethrough
                )
                return Cell(
                    char: text[text.index(text.startIndex, offsetBy: characterIndex)],
                    foregroundColor: foregroundColor,
                    attributes: cellAttributes
                )
            }
            return nil
        }
        
        private var characterCount: Int {
            if #available(macOS 12, *), let attributedText {
                return attributedText.characters.count
            }
            return text?.count ?? 0
        }
    }
}
