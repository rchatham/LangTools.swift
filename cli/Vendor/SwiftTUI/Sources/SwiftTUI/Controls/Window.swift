import Foundation

class Window: LayerDrawing {
    private(set) lazy var layer: Layer = makeLayer()

    private(set) var controls: [Control] = []

    var firstResponder: Control?

    func addControl(_ control: Control) {
        control.window = self
        self.controls.append(control)
        layer.addLayer(control.layer, at: 0)
    }

    private func makeLayer() -> Layer {
        let layer = Layer()
        layer.content = self
        return layer
    }

    func cell(at position: Position) -> Cell? {
        Cell(char: " ")
    }

    /// The first scroll view control in the tree, if any — the target for
    /// keyboard scrolling (PageUp/PageDown/Home/End).
    func firstScrollView() -> ScrollControl? {
        func search(_ control: Control) -> ScrollControl? {
            if let scroll = control as? ScrollControl {
                return scroll
            }
            for child in control.children {
                if let found = search(child) {
                    return found
                }
            }
            return nil
        }
        for control in controls {
            if let found = search(control) {
                return found
            }
        }
        return nil
    }
}
