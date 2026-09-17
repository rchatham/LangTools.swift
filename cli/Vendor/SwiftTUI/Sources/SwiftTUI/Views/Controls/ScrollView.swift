import Foundation

/// Automatically scrolls to the currently active control and supports keyboard
/// scrolling (PageUp/PageDown/Home/End, routed by `Application.handleInput`).
/// New content auto-follows (stays pinned to the bottom) until the user scrolls
/// up; paging back to the bottom resumes following.
public struct ScrollView<Content: View>: View, PrimitiveView {
    let content: VStack<Content>

    public init(@ViewBuilder _ content: () -> Content) {
        self.content = VStack(content: content())
    }

    static var size: Int? { 1 }

    func buildNode(_ node: Node) {
        node.addNode(at: 0, Node(view: content.view))
        let control = ScrollControl()
        control.contentControl = node.children[0].control(at: 0)
        control.addSubview(control.contentControl, at: 0)
        node.control = control
    }

    func updateNode(_ node: Node) {
        node.view = self
        node.children[0].update(using: content.view)
    }
}

public extension ScrollView {
    /// Requests that every scroll view re-follow the bottom on its next layout
    /// pass (e.g. when the user submits a new message from a scrolled-up
    /// position: they intend to see the response).
    static func requestFollowBottom() {
        ScrollControl.requestFollowBottom()
    }
}

/// Scroll math shared with tests: the clamped content offset for a given
/// content height and viewport.
enum ScrollMath {
    static func clampOffset(_ offset: Extended, contentHeight: Extended, viewport: Extended) -> Extended {
        let maxOffset = max(0, contentHeight - viewport)
        return min(max(0, offset), maxOffset)
    }

    static func maxOffset(contentHeight: Extended, viewport: Extended) -> Extended {
        max(0, contentHeight - viewport)
    }
}

/// Top-level (not nested in the generic `ScrollView`) so every instantiation
/// shares one runtime type and the window can find it for keyboard scrolling.
class ScrollControl: Control {
    var contentControl: Control!
    var contentOffset: Extended = 0

    /// Whether the view should follow new content (stay at the bottom).
    /// Cleared when the user scrolls up; restored when they scroll back
    /// to the bottom (or jump there with End).
    var pinnedToBottom: Bool = true

    private static let followLock = NSLock()
    private static var pendingFollowRequests = 0

    /// Requests that every scroll view re-follow the bottom on its next
    /// layout pass (e.g. when the user submits a new message from a scrolled-up
    /// position: they intend to see the response).
    static func requestFollowBottom() {
        followLock.lock()
        pendingFollowRequests += 1
        followLock.unlock()
    }

    private static func consumeFollowRequest() -> Bool {
        followLock.lock()
        defer { followLock.unlock() }
        guard pendingFollowRequests > 0 else { return false }
        pendingFollowRequests -= 1
        return true
    }

    override func layout(size: Size) {
        super.layout(size: size)
        let contentSize = contentControl.size(proposedSize: .zero)
        contentControl.layout(size: contentSize)
        if pinnedToBottom || ScrollControl.consumeFollowRequest() {
            pinnedToBottom = true
            contentOffset = ScrollMath.maxOffset(contentHeight: contentSize.height, viewport: size.height)
        } else {
            contentOffset = ScrollMath.clampOffset(contentOffset, contentHeight: contentSize.height, viewport: size.height)
        }
        contentControl.layer.frame.position.line = -contentOffset
    }

    override func scroll(to position: Position) {
        let destination = position.line - contentControl.layer.frame.position.line
        guard layer.frame.size.height > 0 else { return }
        if contentOffset > destination {
            contentOffset = destination
        } else if contentOffset < destination - layer.frame.size.height + 1 {
            contentOffset = destination - layer.frame.size.height + 1
        }
    }

    /// Scroll `lines` rows (positive = towards older content at the top).
    func scrollBy(lines: Extended) {
        guard lines != 0 else { return }
        let proposed = contentOffset - lines
        let maxOffset = ScrollMath.maxOffset(contentHeight: contentControl.layer.frame.size.height, viewport: layer.frame.size.height)
        contentOffset = ScrollMath.clampOffset(proposed, contentHeight: contentControl.layer.frame.size.height, viewport: layer.frame.size.height)
        pinnedToBottom = proposed >= maxOffset
        layer.invalidate()
    }

    func scrollToBottom() {
        pinnedToBottom = true
        scrollBy(lines: .infinity)
    }

    func scrollToTop() {
        pinnedToBottom = false
        scrollBy(lines: .infinity)
    }
}