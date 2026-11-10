import AppKit
import CoreImage.CIFilterBuiltins
import ObjectiveC.runtime

@MainActor enum UI {
    static let brand = NSColor(srgbRed: 0.28, green: 0.49, blue: 0.50, alpha: 1)
    static let pinnedBackground = NSColor(srgbRed: 0.58, green: 0.74, blue: 0.74, alpha: 1)
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let view = NSTextField(labelWithString: text)
        view.font = .systemFont(ofSize: size * Preferences.scale, weight: weight)
        view.textColor = secondary ? .secondaryLabelColor : .labelColor
        view.lineBreakMode = .byTruncatingTail
        view.maximumNumberOfLines = 1; view.cell?.wraps = false; view.cell?.usesSingleLineMode = true
        return view
    }
    static func paragraph(_ text: String, size: CGFloat = 12) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size * Preferences.scale)
        view.textColor = .secondaryLabelColor
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }
    static func row(_ children: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: children); stack.orientation = .horizontal; stack.spacing = spacing; stack.alignment = .centerY; return stack
    }
    static func column(_ children: [NSView] = [], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: children); stack.orientation = .vertical; stack.spacing = spacing; stack.alignment = .leading; return stack
    }
    static func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.init(1), for: .horizontal); return view
    }
    static func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset), child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
    }
    static func fill(_ child: NSView, in parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
    }
    static func button(_ title: String, target: AnyObject?, action: Selector, symbol: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: target, action: action); b.bezelStyle = .rounded
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        b.setAccessibilityLabel(title); return b
    }
    static func card(_ content: NSView, inset: CGFloat = 16) -> NSView {
        let box = ReadingView(); pin(content, in: box, inset: inset); return box
    }
    static func confirm(title: String, message: String, destructive: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        alert.addButton(withTitle: L("cancel")); alert.addButton(withTitle: destructive)
        alert.buttons[1].hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

@MainActor final class ReadingView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.cornerRadius = 18; update() }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update() }
    private func update() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.backgroundColor = NSColor(white: dark ? 0.12 : 0.98, alpha: opaque ? 1 : 0.90).cgColor
        layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

@MainActor final class GlassSurface: NSView {
    let foreground = NSView()
    private let optical = NSGlassEffectView()
    // 0.1.3 的失焦替代方案会盖住原生玻璃主体，停用并保留记录：
    // private let liveMaterial = NSVisualEffectView()
    // private let glassRim = CAShapeLayer()
    private let container = NSView()
    private let diffusion = NSView()
    private let backing = NSView()
    var usesSchemeInk = true
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 26; layer?.masksToBounds = true
        optical.cornerRadius = 26; optical.style = .clear
        // 内容必须由完整的原生 Liquid Glass 承载。不要把 contentView 换成
        // 空视图、将玻璃裁成外缘，或在上面叠加另一整块系统材质。
        optical.contentView = container
        UI.pin(optical, in: self)
        // 旧失焦替代方案（不再执行）：其整块材质遮住了 Liquid Glass。
        // optical.contentView = NSView()
        // optical.wantsLayer = true; glassRim.fillRule = .evenOdd; optical.layer?.mask = glassRim
        // liveMaterial.material = .sidebar
        // liveMaterial.blendingMode = .behindWindow
        // liveMaterial.state = .active
        // liveMaterial.wantsLayer = true; liveMaterial.layer?.cornerRadius = 24; liveMaterial.layer?.masksToBounds = true
        // UI.pin(liveMaterial, in: self, inset: 2)
        // UI.pin(container, in: liveMaterial)
        UI.pin(diffusion, in: container); diffusion.wantsLayer = true
        UI.pin(backing, in: container); backing.wantsLayer = true
        UI.pin(foreground, in: container)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(update), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .preferencesChanged, object: nil)
        update()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update() }
    // 旧外缘裁切方案导致玻璃中心完全不参与渲染，注释保留，禁止重新接线：
    // override func layout() {
    //     super.layout()
    //     if glassRim.frame != optical.bounds {
    //         glassRim.frame = optical.bounds
    //         let path = CGMutablePath()
    //         path.addRoundedRect(in: optical.bounds, cornerWidth: 26, cornerHeight: 26)
    //         path.addRoundedRect(in: optical.bounds.insetBy(dx: 2, dy: 2), cornerWidth: 24, cornerHeight: 24)
    //         glassRim.path = path
    //     }
    // }
    @objc func update() {
        let scheme = Preferences.glass
        foreground.appearance = usesSchemeInk ? NSAppearance(named: scheme == "ink" ? .aqua : effectiveAppearance.name) : nil
        let dark = (foreground.appearance ?? effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        optical.style = .clear
        let base = NSColor(srgbRed: dark ? 0.12 : 0.92, green: dark ? 0.19 : 0.95, blue: dark ? 0.21 : 0.94, alpha: 1)
        let opacity = reduce || contrast ? 1.0 : dark ? 0.94 : 0.70
        backing.layer?.backgroundColor = base.withAlphaComponent(opacity).cgColor
        // Public background-only filter. Foreground is a later sibling, never filtered.
        let radius = 24 * pow(1 - Preferences.clarity, 1.2)
        if reduce || radius < 0.01 { diffusion.backgroundFilters = [] }
        else { let blur = CIFilter.discBlur(); blur.radius = Float(radius); diffusion.backgroundFilters = [blur] }
        optical.isHidden = false
        // liveMaterial.state = .active // 已停用的替代材质，不重新启用。
        // 旧版为“降低透明度”拆掉玻璃容器的分支，保留以便恢复：
        // if reduce {
        //     if container.superview !== self { optical.contentView = nil; UI.pin(container, in: self) }
        //     optical.isHidden = true
        // } else if optical.contentView == nil {
        //     container.removeFromSuperview(); container.translatesAutoresizingMaskIntoConstraints = true; optical.contentView = container
        // }
        // 应用不随焦点拆装或替换玻璃；KeyPanel 的外观查询兼容层负责保持
        // 活跃材质。系统辅助功能要求的降低透明度仍通过实色阅读衬底生效。
    }
}

@MainActor enum FragmentMark {
    static func image(state: Int = 0, size: NSSize = NSSize(width: 24, height: 18), template: Bool = true) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let sx = rect.width / 24, sy = rect.height / 18
            func path(_ x: CGFloat, _ y: CGFloat) -> NSBezierPath {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x * sx, y: (y + 1) * sy))
                p.curve(to: NSPoint(x: (x + 11) * sx, y: y * sy), controlPoint1: NSPoint(x: (x + 3) * sx, y: y * sy), controlPoint2: NSPoint(x: (x + 9) * sx, y: (y - 1) * sy))
                p.curve(to: NSPoint(x: (x + 13) * sx, y: (y + 7) * sy), controlPoint1: NSPoint(x: (x + 12) * sx, y: (y + 1) * sy), controlPoint2: NSPoint(x: (x + 11) * sx, y: (y + 5) * sy))
                p.curve(to: NSPoint(x: (x + 2) * sx, y: (y + 8) * sy), controlPoint1: NSPoint(x: (x + 8) * sx, y: (y + 6) * sy), controlPoint2: NSPoint(x: (x + 5) * sx, y: (y + 9) * sy))
                p.curve(to: NSPoint(x: x * sx, y: (y + 1) * sy), controlPoint1: NSPoint(x: (x + 1) * sx, y: (y + 7) * sy), controlPoint2: NSPoint(x: (x + 2) * sx, y: (y + 3) * sy)); p.close(); p.lineWidth = 1.1; return p
            }
            NSColor.black.set(); path(1, 1).stroke()
            let front = path(4, 10)
            if state == 0 { front.fill() } else { front.stroke() }
            if state == 1 { NSBezierPath(rect: NSRect(x: 20, y: 10, width: 1.2, height: 7)).fill(); NSBezierPath(rect: NSRect(x: 23, y: 10, width: 1.2, height: 7)).fill() }
            if state == 2 { ("!" as NSString).draw(at: NSPoint(x: 19, y: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.black]) }
            return true
        }
        image.isTemplate = template; return image
    }
}

/// 只向拾影自己的 KeyPanel 增加外观查询，不修改 NSWindow/NSPanel 的实现。
/// AppKit 的原生 Liquid Glass 没有公开的永久 active 开关；这里使用未公开的
/// _hasActiveAppearance，仅在面板固定时返回活跃外观；未固定时调用系统原实现。
/// 它只决定外观，不改变 isKeyWindow/NSApp.keyWindow，
/// 不在失焦时调用 makeKey/activate，也不创建轮询或辅助窗口。
/// 系统升级后若查询不存在或 ABI 改变，则保持系统原生行为，不安装兼容层。
@MainActor enum NativeGlassAppearance {
    static let query = NSSelectorFromString("_hasActiveAppearance")
    // interned selector 的地址作为窗口私有的关联对象键；UInt 可安全跨回调线程读取。
    private nonisolated static let pinnedKey = unsafeBitCast(NSSelectorFromString("shiyingPinnedGlassAppearance"), to: UInt.self)
    private static let installed: Bool = {
        guard let method = class_getInstanceMethod(NSPanel.self, query),
              method_getNumberOfArguments(method) == 2,
              let encoding = method_getTypeEncoding(method) else { return false }
        var result = [CChar](repeating: 0, count: 8)
        method_getReturnType(method, &result, result.count)
        guard result[0] == 66 || result[0] == 99 else { return false } // BOOL: B/c
        let active: @convention(c) (AnyObject, Selector) -> Bool = { window, selector in
            #if DEBUG
            if Thread.isMainThread {
                // 同步 C 回调借用的对象仍存活；只在确认主线程后读取调试计数。
                let address = UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())
                MainActor.assumeIsolated {
                    let object = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
                    (object as? KeyPanel)?.recordGlassAppearanceQuery()
                }
            }
            #endif
            if (objc_getAssociatedObject(window, UnsafeRawPointer(bitPattern: pinnedKey)!) as? NSNumber)?.boolValue == true { return true }
            // 未固定：完全沿用系统外观。基类未被替换，不会递归进入当前实现。
            guard let original = class_getMethodImplementation(NSPanel.self, selector) else { return false }
            let systemAppearance = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            return systemAppearance(window, selector)
        }
        // class_addMethod 只添加到我们自己的子类，不 swizzle 系统类。
        return class_addMethod(KeyPanel.self, query, unsafeBitCast(active, to: IMP.self), encoding)
    }()
    @discardableResult static func installIfSupported() -> Bool { installed }
    static func setPinned(_ pinned: Bool, for panel: KeyPanel) {
        let key = UnsafeRawPointer(bitPattern: pinnedKey)!
        let current = (objc_getAssociatedObject(panel, key) as? NSNumber)?.boolValue ?? false
        guard current != pinned else { return }
        // 关联对象采用原子保留；外观查询只读不可变 NSNumber，不跨线程读取 Swift UI 状态。
        objc_setAssociatedObject(panel, key, pinned ? NSNumber(value: true) : nil, .OBJC_ASSOCIATION_RETAIN)
        panel.contentView?.needsDisplay = true
    }
}

@MainActor final class KeyPanel: NSPanel {
    #if DEBUG
    private(set) var glassAppearanceQueryCount = 0
    func recordGlassAppearanceQuery() { glassAppearanceQueryCount += 1 }
    #endif
    var handleKey: ((NSEvent) -> Bool)?
    weak var dragRegion: PanelDragRegion?
    private var dragging = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        // 在窗口入口接住首次鼠标/三指拖动，避免标签、玻璃子视图或系统窗口
        // 拖动先截走事件。按钮仍走 AppKit 正常路径，不改变按钮和搜索的交互。
        if event.type == .leftMouseDown {
            dragging = false
            if let region = dragRegion, canStartDragging(at: event.locationInWindow) {
                dragging = true; makeKey(); region.mouseDown(with: event); return
            }
        }
        if dragging, let region = dragRegion {
            if event.type == .leftMouseDragged { region.mouseDragged(with: event); return }
            if event.type == .leftMouseUp { dragging = false; region.mouseUp(with: event); return }
        }
        super.sendEvent(event)
    }
    func canStartDragging(at point: NSPoint) -> Bool {
        guard let region = dragRegion, let contentView else { return false }
        let header = region.convert(region.bounds, to: nil)
        guard point.x >= 0, point.x <= contentView.bounds.width,
              point.y >= header.minY, point.y <= contentView.bounds.height else { return false }
        guard let parent = region.superview else { return false }
        var hit = region.hitTest(parent.convert(point, from: nil))
        while let view = hit, view !== region {
            if view is NSButton { return false }
            hit = view.superview
        }
        return true
    }
    func cancelDragging() { dragging = false; dragRegion?.cancelDragging() }
}

@MainActor final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
@MainActor final class PreviewBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.45, green: 0.66, blue: 0.64, alpha: 1), NSColor(srgbRed: 0.82, green: 0.78, blue: 0.63, alpha: 1)])?.draw(in: bounds, angle: 25)
        NSColor.white.withAlphaComponent(0.20).setStroke()
        for i in 0..<20 {
            let path = NSBezierPath(); path.move(to: NSPoint(x: CGFloat(i) * 28, y: 0)); path.line(to: NSPoint(x: CGFloat(i) * 28 + 70, y: bounds.height)); path.lineWidth = 2; path.stroke()
        }
    }
}

/// One drawing rect for every sidebar entry; native borderless cells otherwise put
/// their title flush against the custom selection background.
@MainActor final class SidebarButton: NSButton {
    var selected = false { didSet { needsDisplay = true } }
    static let textInset: CGFloat = 14
    override func draw(_ dirtyRect: NSRect) {
        if selected || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.18 : 0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13 * Preferences.scale, weight: selected ? .medium : .regular), .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor])
        text.draw(at: NSPoint(x: Self.textInset, y: (bounds.height - text.size().height) / 2))
        if window?.firstResponder === self && NSApp.isActive {
            NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
    }
}

/// Only the non-control part of the header moves the panel.
@MainActor final class PanelDragRegion: NSView {
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStart: (pointer: NSPoint, origin: NSPoint)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var ancestor: NSView? = hit
        while let view = ancestor, view !== self {
            if view is NSButton { return hit }
            ancestor = view.superview
        }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (screenPoint(for: event, in: window), window.frame.origin)
        onDragStarted?()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let pointer = screenPoint(for: event, in: window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            window.setFrameOrigin(NSPoint(x: dragStart.origin.x + pointer.x - dragStart.pointer.x,
                                         y: dragStart.origin.y + pointer.y - dragStart.pointer.y))
        }
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil; onDragEnded?() }
    func cancelDragging() { dragStart = nil }
    private func screenPoint(for event: NSEvent, in window: NSWindow) -> NSPoint {
        // 使用事件发生时的屏幕坐标。窗口坐标随移动而改变，用它换算积压的事件
        // 会产生反馈抖动；CGEvent 的全局坐标对鼠标和系统三指拖动一致。
        if let point = event.cgEvent?.location, let primary = NSScreen.screens.first {
            return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}
