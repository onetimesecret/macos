import AppKit

@MainActor
final class PresentationContentContainer: NSView {
    let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: content.frame)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("presentation containers are created in code") }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let overlay = subviews.reversed().compactMap({ $0 as? PaletteOverlayView }).first {
            if overlay.performKeyEquivalent(with: event) { return true }
            if overlay.superview === self { return false }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class PresentationContentContainerController: NSViewController {
    init(content: NSViewController) {
        super.init(nibName: nil, bundle: nil)
        addChild(content)
        view = PresentationContentContainer(content: content.view)
        preferredContentSize = content.preferredContentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("presentation controllers are created in code") }
}
