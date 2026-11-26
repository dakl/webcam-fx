import AppKit

/// The controls under the picture: effect, black outside, hand gestures, help, removing a drawn
/// frame, and the status (fps, hands, camera). `refresh()` shows changes made by pinches and keys too.
final class Toolbar: NSView {
    private let effect = NSPopUpButton()
    private let black = NSButton(checkboxWithTitle: "Black outside", target: nil, action: nil)
    private let gestures = NSButton(checkboxWithTitle: "Hand gestures", target: nil, action: nil)
    private let help = NSButton(checkboxWithTitle: "Help", target: nil, action: nil)
    private let lock = NSButton(checkboxWithTitle: "Lock frame", target: nil, action: nil)
    private let removeFrame = NSButton(title: "Remove frame", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let camera: Camera
    private let frameView: FrameView

    init(camera: Camera, frameView: FrameView) {
        self.camera = camera
        self.frameView = frameView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        effect.addItems(withTitles: effects.all.map(\.name))
        for (control, action) in [(effect as NSControl, #selector(pickEffect)), (black, #selector(setBlack)),
                                  (gestures, #selector(setGestures)), (help, #selector(setHelp)),
                                  (lock, #selector(setLock)), (removeFrame, #selector(remove))] {
            control.target = self
            control.action = action
            control.refusesFirstResponder = true  // keys keep going to the picture
        }
        let tip = NSTextField(labelWithString: "Drag in the picture to draw a frame")
        status.alignment = .right
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for label in [tip, status] {
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [NSTextField(labelWithString: "Effect"), effect, black, gestures, help,
                                        lock, removeFrame, tip, spacer, status])
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Show the current settings. Called many times a second, so it changes only what differs.
    func refresh() {
        let c = camera.controls
        if effect.indexOfSelectedItem != c.selected { effect.selectItem(at: c.selected) }
        for (box, on) in [(black, c.blackOutside), (gestures, c.gesturesOn), (help, c.showHelp)] {
            let state: NSControl.StateValue = on ? .on : .off
            if box.state != state { box.state = state }
        }
        if let text = frameView.scene?.status, status.stringValue != text { status.stringValue = text }
        let hasFrame = frameView.drawnBox != nil
        let canRemove = hasFrame && !frameView.frameLocked
        if removeFrame.isEnabled != canRemove { removeFrame.isEnabled = canRemove }
        let canLock = hasFrame || frameView.frameLocked
        if lock.isEnabled != canLock { lock.isEnabled = canLock }
    }

    @objc private func pickEffect() { camera.select(effect.indexOfSelectedItem) }
    @objc private func setBlack() { camera.setBlackOutside(black.state == .on) }
    @objc private func setGestures() { camera.setGestures(gestures.state == .on) }
    @objc private func setHelp() { camera.setShowHelp(help.state == .on) }
    @objc private func remove() { frameView.drawnBox = nil }
    @objc private func setLock() { frameView.frameLocked = lock.state == .on }
}
