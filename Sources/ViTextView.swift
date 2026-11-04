// ViTextView.swift — draws the buffer and turns hardware key presses into vi keys.

import UIKit

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: alpha) : UIColor(hex: light, alpha: alpha) }
    }
    static let bg = dyn(0xFBFAF7, 0x1B1D21)
    static let fg = dyn(0x2A2B2E, 0xD7DAE0)
    static let gutter = dyn(0xA7A7A2, 0x4F5560)
    static let gutterCurrent = dyn(0x55554F, 0xC5C9D1)
    static let tilde = dyn(0x9DB2D3, 0x3B4A63)
    static let cursorLine = dyn(0xF2EFE7, 0x22252A)
    static let selection = dyn(0xC8DCF7, 0x2E4266)
    static let search = dyn(0xFBE3A0, 0x574817)
    static let incsearch = dyn(0xF3B05A, 0xC08A2E)
    static let cursor = dyn(0x2A2B2E, 0xE5C07B)
    static let cursorText = dyn(0xFBFAF7, 0x1B1D21)
    static let statusBg = dyn(0xEDEAE2, 0x25282E)
    static let statusFg = dyn(0x4A4A46, 0xA9B0BC)
    static let statusDim = dyn(0x8C8B85, 0x6B7280)
    static let error = dyn(0xC0392B, 0xE06C75)
    static let special = dyn(0xC4C1B8, 0x3E4451)
    static let pagerBg = dyn(0xF4F1EA, 0x202328)
    static let prompt = dyn(0x3A8A4F, 0x98C379)
    static let introDim = dyn(0x8C8B85, 0x6B7280)

    static func modeColor(_ m: Mode, label: String) -> UIColor {
        switch m {
        case .insert: return dyn(0x3A8A4F, 0x98C379)
        case .replace: return dyn(0xC0392B, 0xE06C75)
        case .visual, .visualLine: return dyn(0xC2722E, 0xD19A66)
        case .commandLine: return label == "VISUAL" ? dyn(0xC2722E, 0xD19A66) : dyn(0x8E5BB5, 0xC678DD)
        case .normal: return dyn(0x3D7DD8, 0x61AFEF)
        }
    }
}

final class ViTextView: UIView, UIPointerInteractionDelegate {
    let engine: ViEngine
    var onStateChange: (() -> Void)?

    private(set) var fontSize: CGFloat
    private var font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private var boldFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
    private var charW: CGFloat = 8
    private var lineH: CGFloat = 17
    private var textYOffset: CGFloat = 0
    private let padX: CGFloat = 10
    /// Space above the first text row: the window's title-bar area (traffic lights) plus a margin.
    private var padTop: CGFloat { safeAreaInsets.top + 8 }
    private var bellFlash = false

    // Key repeat
    private var heldKeyCode: UIKeyboardHIDUsage?
    private var heldKeys: [Key] = []
    private var repeatTimer: Timer?
    private var systemRepeats = false

    // Scrolling / dragging
    private var panIsScroll = false
    private var lastPan = CGPoint.zero
    private var scrollAccum = CGPoint.zero

    init(engine: ViEngine) {
        self.engine = engine
        let saved = UserDefaults.standard.double(forKey: "ViKitFontSize")
        fontSize = saved >= 8 ? CGFloat(saved) : 14
        super.init(frame: .zero)
        backgroundColor = Theme.bg
        isOpaque = true
        contentMode = .redraw
        configureFont()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedScrollTypesMask = .all
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addInteraction(UIPointerInteraction(delegate: self))

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: ViTextView, _: UITraitCollection) in
            v.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); setNeedsDisplay(); return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); stopRepeat(); heldKeyCode = nil; setNeedsDisplay(); return r }

    // MARK: Font & layout

    func setFontSize(_ s: CGFloat) {
        fontSize = max(8, min(48, s))
        UserDefaults.standard.set(Double(fontSize), forKey: "ViKitFontSize")
        configureFont()
        layoutMetrics()
        setNeedsDisplay()
    }

    private func configureFont() {
        font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        charW = ("M" as NSString).size(withAttributes: [.font: font]).width
        lineH = ceil(font.lineHeight * 1.18)
        textYOffset = floor((lineH - font.lineHeight) / 2)
    }

    private var statusH: CGFloat { lineH + 8 }
    private var cmdH: CGFloat { lineH + 6 }
    private var textAreaBottom: CGFloat { bounds.height - statusH - cmdH }

    private var gutterCols: Int {
        guard engine.opts.number || engine.opts.relativenumber else { return 0 }
        return max(3, String(engine.lines.count).count) + 1
    }
    private var textX: CGFloat { padX + CGFloat(gutterCols) * charW }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutMetrics()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func layoutMetrics() {
        engine.visibleRows = max(1, Int((textAreaBottom - padTop) / lineH))
        engine.visibleCols = max(1, Int((bounds.width - textX - padX) / charW))
        engine.clampCursor()
        engine.scrollToCursor()
    }

    // MARK: Engine plumbing

    func send(_ keys: [Key]) {
        let gutterBefore = gutterCols
        for k in keys { engine.feed(k) }
        if gutterCols != gutterBefore { layoutMetrics() }
        setNeedsDisplay()
        onStateChange?()
    }

    func flashBell() {
        bellFlash = true
        setNeedsDisplay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            self?.bellFlash = false
            self?.setNeedsDisplay()
        }
    }

    // MARK: Keyboard

    private func translate(_ k: UIKey) -> [Key]? {
        switch k.keyCode {
        case .keyboardEscape: return [.escape]
        case .keyboardReturnOrEnter, .keypadEnter: return [.enter]
        case .keyboardDeleteOrBackspace: return [.backspace]
        case .keyboardDeleteForward: return [.delete]
        case .keyboardTab: return [.tab]
        case .keyboardUpArrow: return [.up]
        case .keyboardDownArrow: return [.down]
        case .keyboardLeftArrow: return [.left]
        case .keyboardRightArrow: return [.right]
        case .keyboardHome: return [.home]
        case .keyboardEnd: return [.end]
        case .keyboardPageUp: return [.pageUp]
        case .keyboardPageDown: return [.pageDown]
        default: break
        }
        if k.modifierFlags.contains(.control) {
            let base = k.charactersIgnoringModifiers.lowercased()
            if base == "[" { return [.escape] }
            if let c = base.first, c.isASCII, c.isLetter || "]^\\".contains(c) { return [.ctrl(c)] }
            return nil
        }
        let out: [Key] = k.characters.compactMap { c in
            guard let s = c.unicodeScalars.first else { return nil }
            if (0xF700...0xF8FF).contains(s.value) || s.value < 32 || s.value == 127 { return nil }
            return .char(c)
        }
        return out.isEmpty ? nil : out
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, !key.modifierFlags.contains(.command), let keys = translate(key) else {
                unhandled.insert(press)
                continue
            }
            if key.keyCode == heldKeyCode {
                // The system is delivering its own auto-repeat; stop ours for good.
                systemRepeats = true
                stopRepeat()
            } else {
                stopRepeat()
                heldKeyCode = key.keyCode
                heldKeys = keys
                if !systemRepeats { scheduleRepeat() }
            }
            send(keys)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endPresses(presses)
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        endPresses(presses)
        super.pressesCancelled(presses, with: event)
    }

    private func endPresses(_ presses: Set<UIPress>) {
        for p in presses where p.key?.keyCode == heldKeyCode {
            heldKeyCode = nil
            stopRepeat()
        }
    }

    private func scheduleRepeat() {
        let d = UserDefaults.standard
        let initial = d.object(forKey: "InitialKeyRepeat") != nil ? max(0.1, d.double(forKey: "InitialKeyRepeat") * 0.015) : 0.25
        let interval = d.object(forKey: "KeyRepeat") != nil ? max(0.015, d.double(forKey: "KeyRepeat") * 0.015) : 0.035
        repeatTimer = Timer.scheduledTimer(withTimeInterval: initial, repeats: false) { [weak self] _ in
            guard let self, self.heldKeyCode != nil else { return }
            self.send(self.heldKeys)
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self, self.heldKeyCode != nil else { return }
                self.send(self.heldKeys)
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: Clipboard / edit menu

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)): return engine.isVisual
        case #selector(paste(_:)): return UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)): return true
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) { send(parseKeyNotation("\"+y")) }
    override func cut(_ sender: Any?) { send(parseKeyNotation("\"+d")) }
    override func selectAll(_ sender: Any?) {
        if engine.mode != .normal && !engine.isVisual { send([.escape]) }
        if engine.isVisual { send([.escape]) }
        send(parseKeyNotation("ggVG"))
    }
    override func paste(_ sender: Any?) {
        guard let s = UIPasteboard.general.string else { return }
        switch engine.mode {
        case .insert, .replace, .commandLine:
            engine.insertPastedText(s)
            engine.scrollToCursor()
            setNeedsDisplay()
            onStateChange?()
        default:
            send(parseKeyNotation(engine.isVisual ? "\"+p" : "\"+P"))
        }
    }

    // MARK: Mouse

    private func bufferPosition(_ p: CGPoint) -> (Int, Int) {
        let row = engine.topLine + max(0, Int((p.y - padTop) / lineH))
        let col = engine.leftCol + max(0, Int(((p.x - textX) / charW).rounded(.down)))
        return (row, col)
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        if !isFirstResponder { _ = becomeFirstResponder() }
        let p = g.location(in: self)
        if engine.pager != nil { engine.pager = nil; setNeedsDisplay(); return }
        guard p.y < textAreaBottom else { return }
        let (r, c) = bufferPosition(p)
        if r < engine.lines.count { engine.click(row: r, displayCol: c) }
        else { engine.click(row: engine.lines.count - 1, displayCol: c) }
        setNeedsDisplay()
        onStateChange?()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            panIsScroll = g.numberOfTouches == 0
            lastPan = .zero
            scrollAccum = .zero
            if !panIsScroll {
                if !isFirstResponder { _ = becomeFirstResponder() }
                let (r, c) = bufferPosition(g.location(in: self))
                engine.click(row: r, displayCol: c)
            }
        case .changed:
            if panIsScroll {
                let t = g.translation(in: self)
                scrollAccum.y -= t.y - lastPan.y
                scrollAccum.x -= t.x - lastPan.x
                lastPan = t
                let rows = Int(scrollAccum.y / lineH)
                let cols = Int(scrollAccum.x / charW)
                if rows != 0 || cols != 0 {
                    engine.scroll(lines: rows, columns: cols)
                    scrollAccum.y -= CGFloat(rows) * lineH
                    scrollAccum.x -= CGFloat(cols) * charW
                }
            } else {
                var p = g.location(in: self)
                if p.y > textAreaBottom - lineH { engine.scroll(lines: 1); p.y = textAreaBottom - lineH }
                if p.y < padTop { engine.scroll(lines: -1); p.y = padTop }
                let (r, c) = bufferPosition(p)
                engine.drag(row: r, displayCol: c)
            }
        default: break
        }
        setNeedsDisplay()
        onStateChange?()
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .verticalBeam(length: lineH), constrainedAxes: [])
    }

    // MARK: Drawing

    private func xFor(displayCol dc: Int) -> CGFloat { textX + CGFloat(dc - engine.leftCol) * charW }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        Theme.bg.setFill()
        ctx.fill(bounds)

        let e = engine
        let rows = e.visibleRows
        let ts = max(1, e.opts.tabstop)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.fg]
        let specialAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.special]
        let highlight = e.highlightRegex()
        let showIntro = e.filePath == nil && !e.modified && e.lines.count == 1 && e.lines[0].isEmpty && e.mode == .normal && e.pager == nil

        // Visual selection (as buffer positions)
        var selStart: Pos?, selEnd: Pos?
        let inVisual = e.isVisual || (e.mode == .commandLine && e.modeLabel == "VISUAL")
        if inVisual {
            let r = e.visualRange()
            selStart = r.start; selEnd = r.end
        }

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: textAreaBottom))

        for i in 0..<rows {
            let r = e.topLine + i
            let y = padTop + CGFloat(i) * lineH
            if r >= e.lines.count {
                if !(showIntro && r == 1) {
                    ("~" as NSString).draw(at: CGPoint(x: padX, y: y + textYOffset), withAttributes: [.font: font, .foregroundColor: Theme.tilde])
                }
                continue
            }
            let line = e.lines[r]
            let isCursorRow = r == e.cursor.row

            if e.opts.cursorline && isCursorRow && !inVisual {
                Theme.cursorLine.setFill()
                ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: lineH))
            }

            // Line numbers
            if gutterCols > 0 {
                let n: Int
                if e.opts.relativenumber && !isCursorRow { n = abs(r - e.cursor.row) }
                else if e.opts.relativenumber && !e.opts.number { n = 0 }
                else { n = r + 1 }
                let s = String(n)
                let pad = e.opts.relativenumber && e.opts.number && isCursorRow ? 0 : gutterCols - 1 - s.count
                let x = padX + CGFloat(max(0, pad)) * charW
                (s as NSString).draw(at: CGPoint(x: x, y: y + textYOffset),
                                     withAttributes: [.font: isCursorRow ? boldFont : font, .foregroundColor: isCursorRow ? Theme.gutterCurrent : Theme.gutter])
            }

            ctx.saveGState()
            ctx.clip(to: CGRect(x: textX, y: y, width: bounds.width - textX, height: lineH))

            // Search highlights
            if let re = highlight {
                for (c, len) in e.matches(row: r, regex: re) {
                    let a = e.displayCol(r, c)
                    let b = max(a + 1, e.displayCol(r, c + len))
                    let isCurrent = e.mode == .commandLine && r == e.cursor.row && c == e.cursor.col
                    (isCurrent ? Theme.incsearch : Theme.search).setFill()
                    ctx.fill(CGRect(x: xFor(displayCol: a), y: y, width: CGFloat(b - a) * charW, height: lineH))
                }
            }

            // Visual selection
            if let s = selStart, let en = selEnd {
                var a: Int?, b = 0
                if e.mode == .visualLine || (e.mode == .commandLine && en == Pos(en.row, 0) && s.col == 0 && false) {
                    if r >= s.row && r <= en.row { a = 0; b = max(e.displayCol(r, line.count) + 1, e.leftCol + e.visibleCols + 1) }
                } else if r >= s.row && (r < en.row || (r == en.row && en.col > 0)) {
                    let from = r == s.row ? s.col : 0
                    a = e.displayCol(r, from)
                    if r == en.row { b = e.displayCol(r, en.col) } else { b = e.displayCol(r, line.count) + 1 }
                    b = max(b, a! + 1)
                }
                if let a {
                    Theme.selection.setFill()
                    ctx.fill(CGRect(x: xFor(displayCol: a), y: y, width: CGFloat(b - a) * charW, height: lineH))
                }
            }

            // Text
            let startCol = e.leftCol, endCol = e.leftCol + e.visibleCols + 1
            var dc = 0
            var run = ""
            var runStart = 0
            func flush() {
                if !run.isEmpty {
                    (run as NSString).draw(at: CGPoint(x: xFor(displayCol: runStart), y: y + textYOffset), withAttributes: attrs)
                    run = ""
                }
            }
            for ch in line {
                if dc >= endCol { break }
                let w = ch == "\t" ? ts - dc % ts : 1
                if ch == "\t" {
                    flush()
                    if e.opts.list && dc >= startCol {
                        ("›" as NSString).draw(at: CGPoint(x: xFor(displayCol: dc), y: y + textYOffset), withAttributes: specialAttrs)
                    }
                } else if dc >= startCol {
                    if ch.isASCII, let v = ch.asciiValue, v >= 32, v != 127 {
                        if run.isEmpty { runStart = dc }
                        run.append(ch)
                    } else {
                        flush()
                        let isCtl = ch.asciiValue.map { $0 < 32 || $0 == 127 } ?? false
                        (String(isCtl ? "·" : String(ch)) as NSString).draw(at: CGPoint(x: xFor(displayCol: dc), y: y + textYOffset), withAttributes: isCtl ? specialAttrs : attrs)
                    }
                } else {
                    flush()
                }
                dc += w
            }
            flush()
            if e.opts.list && dc >= startCol && dc < endCol {
                ("¬" as NSString).draw(at: CGPoint(x: xFor(displayCol: dc), y: y + textYOffset), withAttributes: specialAttrs)
            }
            ctx.restoreGState()
        }

        if showIntro { drawIntro() }
        drawCursor(ctx)
        ctx.restoreGState()

        if let p = e.pager { drawPager(ctx, p) }
        drawStatus(ctx)
        drawCommandLine(ctx)
    }

    private func drawCursor(_ ctx: CGContext) {
        let e = engine
        guard e.mode != .commandLine, e.pager == nil else { return }
        let r = e.cursor.row
        guard r >= e.topLine, r < e.topLine + e.visibleRows, r < e.lines.count else { return }
        let dc = e.displayCol(r, e.cursor.col)
        guard dc >= e.leftCol, dc <= e.leftCol + e.visibleCols else { return }
        let x = xFor(displayCol: dc)
        let y = padTop + CGFloat(r - e.topLine) * lineH
        let line = e.lines[r]
        let ch: Character? = e.cursor.col < line.count ? line[e.cursor.col] : nil
        let active = isFirstResponder && (window?.windowScene?.activationState ?? .foregroundActive) == .foregroundActive
        Theme.cursor.setFill()
        Theme.cursor.setStroke()
        switch e.mode {
        case .insert:
            ctx.fill(CGRect(x: x - 1, y: y + 1, width: 2, height: lineH - 2))
        case .replace:
            ctx.fill(CGRect(x: x, y: y + lineH - 3, width: charW, height: 3))
        default:
            let rect = CGRect(x: x, y: y, width: charW, height: lineH)
            if active {
                ctx.fill(rect)
                if let c = ch, c != "\t" {
                    (String(c) as NSString).draw(at: CGPoint(x: x, y: y + textYOffset), withAttributes: [.font: font, .foregroundColor: Theme.cursorText])
                }
            } else {
                ctx.setLineWidth(1)
                ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }
        }
    }

    private func drawIntro() {
        let lines: [(String, Bool)] = [
            ("ViKit", true),
            ("vi for macOS, built with UIKit", false),
            ("", false),
            ("type  :help<Enter>       for help", false),
            ("type  :e file<Enter>     or ⌘O to open a file", false),
            ("type  i                  to start typing", false),
            ("type  :q<Enter>          to exit", false),
        ]
        let total = CGFloat(lines.count) * lineH
        var y = max(padTop + lineH * 2, (textAreaBottom - total) / 2 - lineH)
        for (s, bold) in lines {
            let a: [NSAttributedString.Key: Any] = [.font: bold ? UIFont.monospacedSystemFont(ofSize: fontSize * 1.6, weight: .bold) : font,
                                                    .foregroundColor: bold ? Theme.fg : Theme.introDim]
            let size = (s as NSString).size(withAttributes: a)
            (s as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: y), withAttributes: a)
            y += bold ? size.height + 4 : lineH
        }
    }

    private func drawPager(_ ctx: CGContext, _ lines: [String]) {
        let all = lines.map { visibleControlChars($0) } + ["Press ENTER or type command to continue"]
        let maxRows = max(1, Int((textAreaBottom - padTop) / lineH))
        let shown = Array(all.suffix(maxRows))
        let h = CGFloat(shown.count) * lineH + 8
        let top = textAreaBottom - h
        Theme.pagerBg.setFill()
        ctx.fill(CGRect(x: 0, y: top, width: bounds.width, height: h))
        Theme.special.setFill()
        ctx.fill(CGRect(x: 0, y: top, width: bounds.width, height: 1))
        for (i, s) in shown.enumerated() {
            let isPrompt = i == shown.count - 1
            (s as NSString).draw(at: CGPoint(x: padX, y: top + 4 + CGFloat(i) * lineH + textYOffset),
                                 withAttributes: [.font: isPrompt ? boldFont : font, .foregroundColor: isPrompt ? Theme.prompt : Theme.fg])
        }
    }

    private func drawStatus(_ ctx: CGContext) {
        let e = engine
        let y = textAreaBottom
        Theme.statusBg.setFill()
        ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: statusH))

        let label = e.modeLabel
        let pillFont = UIFont.monospacedSystemFont(ofSize: max(9, fontSize - 2), weight: .bold)
        let pillAttrs: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: Theme.bg]
        let size = (label as NSString).size(withAttributes: pillAttrs)
        let pill = CGRect(x: padX - 4, y: y + 4, width: size.width + 14, height: statusH - 8)
        Theme.modeColor(e.mode, label: label).setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: 4).fill()
        (label as NSString).draw(at: CGPoint(x: pill.minX + 7, y: pill.midY - size.height / 2), withAttributes: pillAttrs)

        let fileAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.statusFg]
        var name = e.displayName
        if e.modified { name += " [+]" }
        (name as NSString).draw(at: CGPoint(x: pill.maxX + 10, y: y + 4 + textYOffset), withAttributes: fileAttrs)

        var right = e.rulerText
        if let r = e.recordingRegister { right = "recording @\(r)   " + right }
        let rAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.statusDim]
        let rs = (right as NSString).size(withAttributes: rAttrs)
        (right as NSString).draw(at: CGPoint(x: bounds.width - padX - rs.width, y: y + 4 + textYOffset), withAttributes: rAttrs)
    }

    private func drawCommandLine(_ ctx: CGContext) {
        let e = engine
        let y = bounds.height - cmdH + 3
        if bellFlash {
            Theme.error.withAlphaComponent(0.18).setFill()
            ctx.fill(CGRect(x: 0, y: bounds.height - cmdH, width: bounds.width, height: cmdH))
        }
        if e.mode == .commandLine {
            let text = String(e.cmdlineType) + visibleControlChars(String(e.cmdlineText))
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.fg]
            (text as NSString).draw(at: CGPoint(x: padX, y: y + textYOffset), withAttributes: a)
            let w = (text as NSString).size(withAttributes: a).width
            Theme.cursor.setFill()
            ctx.fill(CGRect(x: padX + w, y: y + 1, width: 2, height: lineH - 2))
            return
        }
        var text = e.message
        var color = e.messageIsError ? Theme.error : Theme.fg
        var f = font
        if text.isEmpty {
            switch e.mode {
            case .insert: text = "-- INSERT --"
            case .replace: text = "-- REPLACE --"
            case .visual: text = "-- VISUAL --"
            case .visualLine: text = "-- VISUAL LINE --"
            default: break
            }
            if let r = e.recordingRegister { text += (text.isEmpty ? "" : " ") + "recording @\(r)" }
            color = Theme.fg
            f = boldFont
        }
        (visibleControlChars(text) as NSString).draw(at: CGPoint(x: padX, y: y + textYOffset), withAttributes: [.font: f, .foregroundColor: color])
        let sc = e.showcmd
        if !sc.isEmpty {
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.statusDim]
            let s = (sc as NSString).size(withAttributes: a)
            (sc as NSString).draw(at: CGPoint(x: bounds.width - padX - s.width - charW * 14, y: y + textYOffset), withAttributes: a)
        }
    }
}
