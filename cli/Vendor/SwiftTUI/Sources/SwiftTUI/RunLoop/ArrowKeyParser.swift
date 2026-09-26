import Foundation

struct ArrowKeyParser {
    enum ArrowKey {
        case up
        case down
        case right
        case left
        case pageUp
        case pageDown
        case home
        case end
    }

    private var partial: Int = 0
    private var pendingParameters: String = ""

    var arrowKey: ArrowKey?

    mutating func parse(character: Character) -> Bool {
        if partial == 0 && character == "\u{1b}" {
            partial = 1
            pendingParameters = ""
            return true
        }
        if partial == 1 && character == "[" {
            partial = 2
            return true
        }
        if partial == 2 {
            // CSI final byte: a single letter (arrows) or "~"-terminated
            // (page keys, Home/End variants). Digits and ';' are parameters.
            if character == "A" {
                arrowKey = .up
                partial = 0
                return true
            }
            if character == "B" {
                arrowKey = .down
                partial = 0
                return true
            }
            if character == "C" {
                arrowKey = .right
                partial = 0
                return true
            }
            if character == "D" {
                arrowKey = .left
                partial = 0
                return true
            }
            if character == "H" {
                arrowKey = .home
                partial = 0
                return true
            }
            if character == "F" {
                arrowKey = .end
                partial = 0
                return true
            }
            if character == "~" {
                arrowKey = Self.tildeKey(pendingParameters)
                partial = 0
                return arrowKey != nil
            }
            if character.isNumber || character == ";" {
                pendingParameters.append(character)
                return true
            }
        }
        arrowKey = nil
        partial = 0
        pendingParameters = ""
        return false
    }

    private static func tildeKey(_ parameters: String) -> ArrowKey? {
        switch parameters {
        case "1", "7": return .home
        case "4", "8": return .end
        case "5": return .pageUp
        case "6": return .pageDown
        default: return nil
        }
    }
}