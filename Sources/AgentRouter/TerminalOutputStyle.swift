import SwiftUI

/// Renders the SGR attributes returned by tmux capture-pane -e, without executing
/// terminal controls. Its characters remain the complete plain text for copying.
enum TerminalOutputStyle {
    private struct Style {
        var foreground: Color?
        var background: Color?
        var bold = false
        var italic = false
        var dim = false
        var reverse = false

        mutating func apply(_ codes: [Int]) {
            var i = 0
            while i < codes.count {
                let code = codes[i]
                switch code {
                case 0: self = Style()
                case 1: bold = true
                case 2: dim = true
                case 3: italic = true
                case 7: reverse = true
                case 22: bold = false; dim = false
                case 23: italic = false
                case 27: reverse = false
                case 30...37: foreground = TerminalOutputStyle.palette(code - 30)
                case 40...47: background = TerminalOutputStyle.palette(code - 40)
                case 90...97: foreground = TerminalOutputStyle.palette(code - 90 + 8)
                case 100...107: background = TerminalOutputStyle.palette(code - 100 + 8)
                case 39: foreground = nil
                case 49: background = nil
                case 38, 48:
                    var color: Color?
                    if i + 2 < codes.count, codes[i + 1] == 5 {
                        color = TerminalOutputStyle.palette(codes[i + 2]); i += 2
                    } else if i + 4 < codes.count, codes[i + 1] == 2 {
                        color = TerminalOutputStyle.rgb(codes[i + 2], codes[i + 3], codes[i + 4]); i += 4
                    }
                    if let color {
                        if code == 38 { foreground = color } else { background = color }
                    }
                default: break
                }
                i += 1
            }
        }

        func text(_ value: Substring) -> AttributedString {
            var result = AttributedString(String(value))
            var font = Font.system(size: 13, design: .monospaced)
            if bold { font = font.bold() }
            if italic { font = font.italic() }
            result.font = font
            let foreground = foreground ?? .white
            let background = background ?? .black
            result.foregroundColor = (reverse ? background : foreground).opacity(dim ? 0.65 : 1)
            result.backgroundColor = reverse ? foreground : background
            return result
        }
    }

    static func render(_ source: String) -> AttributedString {
        var result = AttributedString()
        var style = Style()
        var cursor = source.startIndex
        while let escape = source.range(of: "\u{1B}[", range: cursor..<source.endIndex) {
            result.append(style.text(source[cursor..<escape.lowerBound]))
            var end = escape.upperBound
            while end < source.endIndex {
                let character = source[end]
                if let ascii = character.asciiValue, (64...126).contains(ascii) { break }
                end = source.index(after: end)
            }
            guard end < source.endIndex else {
                result.append(style.text(source[escape.lowerBound...])); return result
            }
            if source[end] == "m" {
                let parameters = source[escape.upperBound..<end]
                // tmux emits semicolon-delimited SGR, including 256 and RGB colors.
                let codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                style.apply(codes)
            }
            cursor = source.index(after: end)
        }
        result.append(style.text(source[cursor...]))
        return result
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        Color(red: Double(min(255, max(0, red))) / 255,
              green: Double(min(255, max(0, green))) / 255,
              blue: Double(min(255, max(0, blue))) / 255)
    }

    private static func palette(_ index: Int) -> Color {
        let basic: [(Int, Int, Int)] = [
            (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
            (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
            (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
            (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)
        ]
        switch index {
        case 0..<16:
            let (red, green, blue) = basic[index]; return rgb(red, green, blue)
        case 16..<232:
            let n = index - 16
            let levels = [0, 95, 135, 175, 215, 255]
            return rgb(levels[n / 36], levels[(n / 6) % 6], levels[n % 6])
        case 232..<256:
            let gray = 8 + (index - 232) * 10; return rgb(gray, gray, gray)
        default: return .white
        }
    }
}
