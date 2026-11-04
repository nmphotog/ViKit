// ViEngine.swift — a UI-independent vi/vim editing engine.
// Only depends on Foundation so it can be unit-tested headless.

import Foundation

// MARK: - Basic types

enum Key: Hashable {
    case char(Character)
    case ctrl(Character)
    case escape, enter, backspace, delete, tab
    case up, down, left, right, home, end, pageUp, pageDown
}

struct Pos: Comparable, Hashable {
    var row: Int
    var col: Int
    init(_ row: Int, _ col: Int) { self.row = row; self.col = col }
    static func < (a: Pos, b: Pos) -> Bool { a.row != b.row ? a.row < b.row : a.col < b.col }
}

enum Mode: Equatable { case normal, insert, replace, visual, visualLine, commandLine }

enum MotionKind { case exclusive, inclusive, linewise }

struct RegisterContent: Equatable {
    var lines: [[Character]]
    var linewise: Bool
    var text: String { lines.map { String($0) }.joined(separator: "\n") + (linewise ? "\n" : "") }
    static func from(_ s: String) -> RegisterContent {
        if s.hasSuffix("\n") {
            let body = String(s.dropLast())
            return RegisterContent(lines: body.components(separatedBy: "\n").map { Array($0) }, linewise: true)
        }
        return RegisterContent(lines: s.components(separatedBy: "\n").map { Array($0) }, linewise: false)
    }
}

struct MotionSpec { var name: String; var arg: Character? = nil }

struct Cmd {
    var register: Character? = nil
    var count: Int? = nil
    var name: String = ""
    var arg: Character? = nil
    var motion: MotionSpec? = nil
}

/// Charwise ranges have an exclusive `end`; linewise ranges cover rows start.row...end.row.
struct TextRange { var start: Pos; var end: Pos; var linewise: Bool }

struct ExError: Error { let msg: String; init(_ m: String) { msg = m } }

struct Options {
    var number = false
    var relativenumber = false
    var ignorecase = false
    var smartcase = false
    var hlsearch = true
    var incsearch = true
    var expandtab = false
    var autoindent = true
    var wrapscan = true
    var cursorline = false
    var list = false
    var tabstop = 8
    var shiftwidth = 8
    var softtabstop = 0
    var scrolloff = 3
    var clipboard = ""

    static let bools: [(String, String, WritableKeyPath<Options, Bool>)] = [
        ("number", "nu", \.number), ("relativenumber", "rnu", \.relativenumber),
        ("ignorecase", "ic", \.ignorecase), ("smartcase", "scs", \.smartcase),
        ("hlsearch", "hls", \.hlsearch), ("incsearch", "is", \.incsearch),
        ("expandtab", "et", \.expandtab), ("autoindent", "ai", \.autoindent),
        ("wrapscan", "ws", \.wrapscan), ("cursorline", "cul", \.cursorline),
        ("list", "list", \.list),
    ]
    static let ints: [(String, String, WritableKeyPath<Options, Int>)] = [
        ("tabstop", "ts", \.tabstop), ("shiftwidth", "sw", \.shiftwidth),
        ("softtabstop", "sts", \.softtabstop), ("scrolloff", "so", \.scrolloff),
    ]
}

private enum Step<T> {
    case ok(T), incomplete, invalid
    var failed: Step<Cmd> { if case .incomplete = self { return .incomplete }; return .invalid }
}

@inline(__always) func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" }

private func charClass(_ c: Character, _ big: Bool) -> Int {
    if isBlank(c) { return 0 }
    if big { return 2 }
    if c.isLetter || c.isNumber || c == "_" { return 2 }
    return 1
}

private func toggledCase(_ c: Character) -> Character {
    let s = String(c)
    let t = c.isUppercase ? s.lowercased() : s.uppercased()
    return t.count == 1 ? t.first! : c
}

// MARK: - Key notation helpers

func parseKeyNotation(_ s: String) -> [Key] {
    var keys: [Key] = []
    let chars = Array(s)
    var i = 0
    let named: [String: Key] = ["esc": .escape, "cr": .enter, "enter": .enter, "return": .enter, "bs": .backspace,
                                "del": .delete, "tab": .tab, "up": .up, "down": .down, "left": .left, "right": .right,
                                "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown, "lt": .char("<"),
                                "space": .char(" "), "bar": .char("|"), "bslash": .char("\\")]
    while i < chars.count {
        if chars[i] == "<", let close = chars[(i + 1)...].firstIndex(of: ">"), close - i <= 10 {
            let name = String(chars[(i + 1)..<close]).lowercased()
            if let k = named[name] { keys.append(k); i = close + 1; continue }
            if name.hasPrefix("c-"), name.count == 3 { keys.append(.ctrl(name.last!)); i = close + 1; continue }
        }
        keys.append(.char(chars[i]))
        i += 1
    }
    return keys
}

/// Encodes keys as a register string (control chars like vim, private-use chars for arrows).
func keysToRegisterString(_ keys: [Key]) -> String {
    var s = ""
    for k in keys {
        switch k {
        case .char(let c): s.append(c)
        case .ctrl(let c):
            if let a = c.asciiValue, a >= 97, a <= 122 { s.unicodeScalars.append(Unicode.Scalar(a - 96)) }
            else if c == "[" { s.append("\u{1B}") }
        case .escape: s.append("\u{1B}")
        case .enter: s.append("\r")
        case .backspace: s.append("\u{08}")
        case .tab: s.append("\t")
        case .delete: s.append("\u{7F}")
        case .up: s.append("\u{F700}")
        case .down: s.append("\u{F701}")
        case .left: s.append("\u{F702}")
        case .right: s.append("\u{F703}")
        case .home: s.append("\u{F729}")
        case .end: s.append("\u{F72B}")
        case .pageUp: s.append("\u{F72C}")
        case .pageDown: s.append("\u{F72D}")
        }
    }
    return s
}

func registerStringToKeys(_ s: String) -> [Key] {
    var keys: [Key] = []
    for c in s {
        switch c {
        case "\u{1B}": keys.append(.escape)
        case "\r", "\n": keys.append(.enter)
        case "\u{08}": keys.append(.backspace)
        case "\t": keys.append(.tab)
        case "\u{7F}": keys.append(.delete)
        case "\u{F700}": keys.append(.up)
        case "\u{F701}": keys.append(.down)
        case "\u{F702}": keys.append(.left)
        case "\u{F703}": keys.append(.right)
        case "\u{F729}": keys.append(.home)
        case "\u{F72B}": keys.append(.end)
        case "\u{F72C}": keys.append(.pageUp)
        case "\u{F72D}": keys.append(.pageDown)
        default:
            if let v = c.asciiValue, v >= 1, v <= 26 { keys.append(.ctrl(Character(Unicode.Scalar(v + 96)))) }
            else { keys.append(.char(c)) }
        }
    }
    return keys
}

func displayKeys(_ keys: [Key]) -> String {
    keys.map { k -> String in
        switch k {
        case .char(let c): return String(c)
        case .ctrl(let c): return "^" + String(c).uppercased()
        case .escape: return "^["
        case .enter: return "^M"
        case .backspace: return "<BS>"
        case .tab: return "^I"
        default: return ""
        }
    }.joined()
}

/// Replace control characters for on-screen display.
func visibleControlChars(_ s: String) -> String {
    var out = ""
    for c in s {
        if let v = c.asciiValue, v < 32, c != "\t" { out += "^" + String(Character(Unicode.Scalar(v + 64))) }
        else if c == "\u{7F}" { out += "^?" }
        else { out.append(c) }
    }
    return out
}

// MARK: - Engine

final class ViEngine {
    // Buffer
    var lines: [[Character]] = [[]]
    var cursor = Pos(0, 0)
    var curswant = 0
    var mode: Mode = .normal
    var opts = Options()
    var filePath: String?
    var dosLineEndings = false
    var noEolAtEof = false

    private var stateId = 0
    private var savedStateId = 0
    private var nextStateId = 1
    var modified: Bool { stateId != savedStateId }

    // Viewport (set by the host view)
    var topLine = 0
    var leftCol = 0
    var visibleRows = 40
    var visibleCols = 120

    // Messages
    var message = ""
    var messageIsError = false
    var pager: [String]?

    // Command line
    var cmdlineType: Character = ":"
    var cmdlineText: [Character] = []
    private var modeBeforeCmdline: Mode = .normal
    private var cmdlineOrigin = Pos(0, 0)
    private var cmdlineTopOrigin = 0
    private var cmdHistory: [String] = []
    private var searchHistory: [String] = []
    private var historyIndex: Int?
    private var cmdlineCtrlR = false

    // Visual
    var visualAnchor = Pos(0, 0)
    private var lastVisual: (anchor: Pos, cursor: Pos, mode: Mode)?

    // Pending normal-mode keys
    var pendingKeys: [Key] = []

    // Registers / macros
    var registers: [Character: RegisterContent] = [:]
    var recordingRegister: Character?
    private var recordBuffer: [Key] = []
    private var lastMacro: Character?

    // Marks
    var marks: [Character: Pos] = [:]

    // Search
    var lastSearch: String?
    var lastSearchForward = true
    var hlsearchActive = true
    private var lastFind: (Character, Character)?
    private var lastSubstitute: (pattern: String, replacement: String, flags: String)?
    private var lastExCommand: String?
    private var regexCache: [String: NSRegularExpression] = [:]

    // Undo
    private struct Snapshot { var lines: [[Character]]; var cursor: Pos; var stateId: Int }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var pendingUndo: Snapshot?

    // Insert / dot-repeat
    private var lastChange: (cmd: Cmd, insertKeys: [Key])?
    private var recordingChange: Cmd?
    private var insertKeys: [Key] = []
    private var captureInsert = true
    private var insertRepeat = 1
    private var insertOpenLine = false
    private var replayingDot = false
    private var insertStart = Pos(0, 0)
    private var insertCtrlR = false
    private var replaceOriginals: [Character?] = []
    private var lastInserted = ""

    private var depth = 0
    private var lineEditLog: [(at: Int, delta: Int, removedEnd: Int)]?
    private var scrollAmount: Int?

    // Host callbacks
    var onQuit: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onBell: (() -> Void)?
    var clipboardGet: (() -> String?)?
    var clipboardSet: ((String) -> Void)?

    init() {}

    var isVisual: Bool { mode == .visual || mode == .visualLine }
    private var ts: Int { max(1, opts.tabstop) }
    private var sw: Int { opts.shiftwidth > 0 ? opts.shiftwidth : ts }
    private var lastRow: Int { lines.count - 1 }

    // MARK: Buffer helpers

    func lineLen(_ r: Int) -> Int { lines[r].count }
    private func charAt(_ p: Pos) -> Character? {
        guard p.row >= 0, p.row < lines.count, p.col >= 0, p.col < lines[p.row].count else { return nil }
        return lines[p.row][p.col]
    }
    private func touch() { stateId = nextStateId; nextStateId += 1 }

    func firstNonBlank(_ r: Int) -> Int {
        let l = lines[r]
        if let i = l.firstIndex(where: { !isBlank($0) }) { return i }
        return max(0, l.count - 1)
    }
    private func firstNonBlankStrict(_ r: Int) -> Int { lines[r].firstIndex(where: { !isBlank($0) }) ?? lines[r].count }
    private func leadingWS(_ r: Int) -> [Character] { Array(lines[r].prefix(while: isBlank)) }

    func displayCol(_ r: Int, _ col: Int) -> Int {
        let l = lines[r]
        var d = 0
        let n = min(col, l.count)
        for i in 0..<n { d += l[i] == "\t" ? ts - d % ts : 1 }
        if col > l.count { d += col - l.count }
        return d
    }
    func colFor(_ r: Int, _ want: Int, allowEnd: Bool = false) -> Int {
        let l = lines[r]
        if l.isEmpty { return 0 }
        if want == Int.max { return allowEnd ? l.count : l.count - 1 }
        var d = 0
        for (i, ch) in l.enumerated() {
            let w = ch == "\t" ? ts - d % ts : 1
            if d + w > want { return i }
            d += w
        }
        return allowEnd ? l.count : l.count - 1
    }
    private func updateCurswant() { curswant = displayCol(cursor.row, cursor.col) }

    private func insertLines(_ new: [[Character]], at: Int) {
        guard !new.isEmpty else { return }
        lines.insert(contentsOf: new, at: at)
        lineEditLog?.append((at, new.count, 0))
        for (k, p) in marks where p.row >= at { marks[k] = Pos(p.row + new.count, p.col) }
        touch()
    }
    private func removeLines(_ r: Range<Int>) {
        guard !r.isEmpty else { return }
        lines.removeSubrange(r)
        if lines.isEmpty { lines = [[]] }
        lineEditLog?.append((r.lowerBound, -r.count, r.upperBound))
        for (k, p) in marks {
            if p.row >= r.upperBound { marks[k] = Pos(p.row - r.count, p.col) }
            else if p.row >= r.lowerBound, k.isLowercase { marks[k] = nil }
        }
        touch()
    }
    private func setLine(_ r: Int, _ l: [Character]) { lines[r] = l; touch() }

    /// Inserts charwise text; returns position just after the inserted text.
    @discardableResult
    private func insertText(_ parts: [[Character]], at p: Pos) -> Pos {
        if parts.count == 1 {
            lines[p.row].insert(contentsOf: parts[0], at: p.col)
            touch()
            return Pos(p.row, p.col + parts[0].count)
        }
        let tail = Array(lines[p.row][p.col...])
        setLine(p.row, Array(lines[p.row][..<p.col]) + parts[0])
        var rest = Array(parts[1...])
        let lastLen = rest[rest.count - 1].count
        rest[rest.count - 1] += tail
        insertLines(rest, at: p.row + 1)
        return Pos(p.row + parts.count - 1, lastLen)
    }

    private func extract(_ r: TextRange) -> RegisterContent {
        if r.linewise { return RegisterContent(lines: Array(lines[r.start.row...r.end.row]), linewise: true) }
        let s = r.start, e = r.end
        if s.row == e.row { return RegisterContent(lines: [Array(lines[s.row][s.col..<e.col])], linewise: false) }
        var out = [Array(lines[s.row][s.col...])]
        if e.row - s.row > 1 { for row in (s.row + 1)..<e.row { out.append(lines[row]) } }
        out.append(Array(lines[e.row][..<e.col]))
        return RegisterContent(lines: out, linewise: false)
    }

    private func deleteRange(_ r: TextRange) {
        if r.linewise { removeLines(r.start.row..<(r.end.row + 1)); return }
        let s = r.start, e = r.end
        if s.row == e.row {
            lines[s.row].removeSubrange(s.col..<e.col)
            touch()
        } else {
            setLine(s.row, Array(lines[s.row][..<s.col]) + Array(lines[e.row][e.col...]))
            removeLines((s.row + 1)..<(e.row + 1))
        }
    }

    // MARK: Loading / saving

    func load(text: String) {
        var t = text
        dosLineEndings = t.contains("\r\n")
        if dosLineEndings { t = t.replacingOccurrences(of: "\r\n", with: "\n") }
        var parts = t.components(separatedBy: "\n")
        noEolAtEof = false
        if parts.count > 1, parts.last == "" { parts.removeLast() } else if !t.isEmpty { noEolAtEof = true }
        lines = parts.map { Array($0) }
        if lines.isEmpty { lines = [[]] }
        resetBufferState()
    }

    private func resetBufferState() {
        cursor = Pos(0, 0); curswant = 0; topLine = 0; leftCol = 0
        undoStack = []; redoStack = []; pendingUndo = nil
        marks = [:]
        touch(); savedStateId = stateId
        mode = .normal; pendingKeys = []
    }

    static func expandPath(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("~") {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            s = home + s.dropFirst()
        }
        if !s.hasPrefix("/") { s = FileManager.default.currentDirectoryPath + "/" + s }
        return (s as NSString).standardizingPath
    }

    var displayName: String {
        guard let p = filePath else { return "[No Name]" }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let cwd = FileManager.default.currentDirectoryPath
        if cwd != "/", p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    func openFile(_ path: String) {
        let p = ViEngine.expandPath(path)
        filePath = p
        if let data = FileManager.default.contents(atPath: p) {
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            load(text: text)
            setMessage("\"\(displayName)\" \(noEolAtEof ? "[noeol] " : "")\(dosLineEndings ? "[dos] " : "")\(lines.count)L, \(data.count)B")
        } else {
            load(text: "")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                setError("\"\(displayName)\" is a directory")
            } else {
                setMessage("\"\(displayName)\" [New]")
            }
        }
    }

    func bufferText() -> String {
        if lines.count == 1 && lines[0].isEmpty { return "" }
        let eol = dosLineEndings ? "\r\n" : "\n"
        var t = lines.map { String($0) }.joined(separator: eol)
        if !noEolAtEof { t += eol }
        return t
    }

    func write(to path: String) throws {
        let data = Data(bufferText().utf8)
        do { try data.write(to: URL(fileURLWithPath: path)) } catch {
            throw ExError("E212: Can't open file for writing: \(error.localizedDescription)")
        }
        let isNew = filePath == nil
        if isNew { filePath = path }
        if path == filePath { savedStateId = stateId }
        let name = path == filePath ? displayName : path
        setMessage("\"\(name)\" \(lines.count)L, \(data.count)B written")
    }

    /// Called by the host after an external save (e.g. a save panel) succeeded.
    func markSaved(path: String) {
        filePath = path
        savedStateId = stateId
        setMessage("\"\(displayName)\" \(lines.count)L written")
    }

    func loadRC() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        for name in [".exrc", ".vimrc", ".vikitrc"] {
            guard let s = try? String(contentsOfFile: home + "/" + name, encoding: .utf8) else { continue }
            for raw in s.components(separatedBy: .newlines) {
                var l = raw.trimmingCharacters(in: .whitespaces)
                while l.hasPrefix(":") { l.removeFirst() }
                if let q = l.range(of: " \"") { l = String(l[..<q.lowerBound]) }
                if l.hasPrefix("set ") || l.hasPrefix("se ") {
                    let arg = l.drop(while: { $0 != " " })
                    // Only apply options we know; ignore anything else silently.
                    for tok in arg.split(separator: " ") { try? setOptions(String(tok)) }
                }
            }
        }
        message = ""
    }

    // MARK: Messages

    func setMessage(_ m: String) { message = m; messageIsError = false }
    func setError(_ m: String) { message = m; messageIsError = true; onBell?() }
    private func bell() { onBell?() }

    // MARK: Undo

    private func snapshot() -> Snapshot { Snapshot(lines: lines, cursor: cursor, stateId: stateId) }

    private func finalizeUndo() {
        guard mode == .normal || isVisual, pendingKeys.isEmpty else { return }
        if let p = pendingUndo, p.stateId != stateId {
            undoStack.append(p)
            if undoStack.count > 1000 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        pendingUndo = nil
    }

    private func undo(_ n: Int) {
        var done = 0
        for _ in 0..<n {
            guard let s = undoStack.popLast() else { break }
            redoStack.append(snapshot())
            lines = s.lines; cursor = s.cursor; stateId = s.stateId
            done += 1
        }
        pendingUndo = nil
        if done == 0 { setError("Already at oldest change") }
        else { setMessage("\(done) change\(done == 1 ? "" : "s"); before #\(undoStack.count + 1)") }
    }

    private func redo(_ n: Int) {
        var done = 0
        for _ in 0..<n {
            guard let s = redoStack.popLast() else { break }
            undoStack.append(snapshot())
            lines = s.lines; cursor = s.cursor; stateId = s.stateId
            done += 1
        }
        pendingUndo = nil
        if done == 0 { setError("Already at newest change") }
        else { setMessage("\(done) change\(done == 1 ? "" : "s"); after #\(undoStack.count)") }
    }

    // MARK: Key entry point

    func feed(_ key: Key) {
        if depth == 0, pager != nil {
            pager = nil
            if key != .char(":") { return }
        }
        if depth == 0, recordingRegister != nil { recordBuffer.append(key) }
        depth += 1
        defer { depth -= 1 }
        if depth == 1 {
            if pendingUndo == nil && (mode == .normal || isVisual) { pendingUndo = snapshot() }
            if mode == .normal && pendingKeys.isEmpty { message = "" }
        }
        switch mode {
        case .insert, .replace: insertKey(key)
        case .commandLine: cmdlineKey(key)
        default: normalKey(key)
        }
        if depth == 1 {
            finalizeUndo()
            clampCursor()
            scrollToCursor()
        }
    }

    func feed(_ keys: [Key]) { for k in keys { feed(k) } }

    func clampCursor() {
        cursor.row = max(0, min(cursor.row, lastRow))
        let len = lines[cursor.row].count
        switch mode {
        case .insert, .replace: cursor.col = max(0, min(cursor.col, len))
        default: cursor.col = max(0, min(cursor.col, max(0, len - 1)))
        }
        if isVisual {
            visualAnchor.row = max(0, min(visualAnchor.row, lastRow))
            visualAnchor.col = max(0, min(visualAnchor.col, max(0, lines[visualAnchor.row].count - 1)))
        }
    }

    private var effectiveScrolloff: Int { min(opts.scrolloff, max(0, (visibleRows - 1) / 2)) }

    func scrollToCursor() {
        let rows = max(1, visibleRows)
        let so = effectiveScrolloff
        if cursor.row - so < topLine { topLine = max(0, cursor.row - so) }
        else if cursor.row + so > topLine + rows - 1 { topLine = max(0, min(cursor.row + so, lastRow) - rows + 1) }
        if cursor.row < topLine { topLine = cursor.row }
        if cursor.row > topLine + rows - 1 { topLine = cursor.row - rows + 1 }
        topLine = max(0, min(topLine, lastRow))
        let dc = displayCol(cursor.row, cursor.col)
        let cols = max(1, visibleCols)
        if dc < leftCol { leftCol = max(0, dc - cols / 4) }
        else if dc >= leftCol + cols { leftCol = dc - cols + cols / 4 + 1 }
        if leftCol > 0 && lines[cursor.row].count < cols && dc < cols { leftCol = 0 }
    }

    private func keepCursorInView() {
        let so = effectiveScrolloff
        let bottom = topLine + max(1, visibleRows) - 1
        if cursor.row < topLine + so { cursor.row = min(lastRow, topLine + so) }
        if cursor.row > bottom - so { cursor.row = max(topLine, min(lastRow, bottom - so)) }
        cursor.col = colFor(cursor.row, curswant, allowEnd: mode == .insert)
    }

    /// Mouse-wheel / trackpad scrolling from the host view.
    func scroll(lines delta: Int, columns hdelta: Int = 0) {
        if delta != 0 {
            topLine = max(0, min(lastRow, topLine + delta))
            keepCursorInView()
        }
        if hdelta != 0 {
            let maxLen = lines[topLine..<min(lines.count, topLine + visibleRows)].map { $0.count }.max() ?? 0
            leftCol = max(0, min(max(0, maxLen - visibleCols / 2), leftCol + hdelta))
            let dc = displayCol(cursor.row, cursor.col)
            if dc < leftCol { cursor.col = colFor(cursor.row, leftCol) }
            else if dc >= leftCol + visibleCols { cursor.col = colFor(cursor.row, leftCol + visibleCols - 1) }
        }
        clampCursor()
    }

    /// Mouse click at a buffer row / display column.
    func click(row: Int, displayCol dc: Int) {
        if mode == .commandLine { cancelCmdline() }
        pendingKeys = []
        if isVisual { exitVisual() }
        let r = max(0, min(row, lastRow))
        cursor = Pos(r, colFor(r, max(0, dc), allowEnd: mode == .insert))
        updateCurswant()
        clampCursor()
    }

    func drag(row: Int, displayCol dc: Int) {
        guard mode == .normal || isVisual else { return }
        let r = max(0, min(row, lastRow))
        let p = Pos(r, colFor(r, max(0, dc)))
        if !isVisual {
            if p == cursor { return }
            visualAnchor = cursor
            mode = .visual
        }
        cursor = p
        updateCurswant()
        clampCursor()
        scrollToCursor()
    }

    // MARK: Normal mode parsing

    private static let motionNames: Set<String> = [
        "h", "j", "k", "l", "w", "W", "b", "B", "e", "E", "ge", "gE", "0", "^", "$", "g_", "gg", "G",
        "f", "F", "t", "T", ";", ",", "%", "H", "M", "L", "{", "}", "n", "N", "*", "#", "'", "`",
        "+", "-", "<CR>", "_", "|", "gj", "gk", "g0", "g$", "g^", "gm",
    ]
    private static let argMotions: Set<String> = ["f", "F", "t", "T", "'", "`"]
    private static let jumpMotions: Set<String> = ["G", "gg", "%", "'", "`", "n", "N", "*", "#", "{", "}", "H", "M", "L"]
    private static let operators: Set<String> = ["d", "c", "y", "<", ">", "g~", "gu", "gU"]
    private static let argCommands: Set<String> = ["r", "m", "@", "q"]
    private static let scrollCommands: Set<String> = ["^e", "^y", "^d", "^u", "^f", "^b", "zz", "zt", "zb", "z.", "z<CR>", "z-"]
    private static let normalCommands: Set<String> = [
        "x", "X", "D", "C", "s", "S", "Y", "p", "P", "gp", "gP", "J", "gJ", "R", "u", "^r", ".", "~",
        "v", "V", ":", "/", "?", "i", "a", "I", "A", "o", "O", "gI", "gi", "ZZ", "ZQ", "^g", "gv",
        "^a", "^x", "&", "^l", "U",
    ]
    private static let visualCommands: Set<String> = [
        "d", "x", "X", "D", "y", "Y", "c", "s", "C", "S", "R", "r", "~", "u", "U", "<", ">", "J", "gJ",
        "p", "P", "o", "O", "v", "V", ":", "/", "?", "I", "A", "g~", "gu", "gU", "gv",
    ]
    private static let changeCommands: Set<String> = [
        "x", "X", "D", "C", "s", "S", "p", "P", "gp", "gP", "J", "gJ", "r", "R", "~", "i", "a", "I", "A",
        "o", "O", "gI", "gi", "^a", "^x", "d", "c", "<", ">", "g~", "gu", "gU",
    ]

    static func isRegisterName(_ r: Character) -> Bool {
        r.isLetter && r.isASCII || r.isNumber || "\"-+*_.:/%".contains(r)
    }

    private func keyName(_ k: Key) -> String? {
        switch k {
        case .char(let c): return c == " " ? "l" : String(c)
        case .ctrl(let c):
            switch c {
            case "h": return "h"
            case "n", "j": return "j"
            case "p": return "k"
            case "m": return "<CR>"
            default: return "^" + String(c)
            }
        case .enter: return "<CR>"
        case .backspace: return "h"
        case .delete: return "x"
        case .tab: return "<Tab>"
        case .up: return "k"
        case .down: return "j"
        case .left: return "h"
        case .right: return "l"
        case .home: return "0"
        case .end: return "$"
        case .pageUp: return "^b"
        case .pageDown: return "^f"
        case .escape: return nil
        }
    }

    private func parseCount(_ keys: [Key], _ i: inout Int) -> Int? {
        guard i < keys.count, case .char(let c) = keys[i], let d = c.wholeNumberValue, d > 0, c.isASCII else { return nil }
        var v = 0
        while i < keys.count, case .char(let c) = keys[i], let d = c.wholeNumberValue, c.isASCII {
            v = min(v * 10 + d, 999_999)
            i += 1
        }
        return v
    }

    private func readName(_ keys: [Key], _ i: inout Int) -> Step<String> {
        guard i < keys.count else { return .incomplete }
        guard let n = keyName(keys[i]) else { return .invalid }
        i += 1
        if n == "g" || n == "z" || n == "Z" {
            guard i < keys.count else { return .incomplete }
            guard let n2 = keyName(keys[i]) else { return .invalid }
            i += 1
            return .ok(n + n2)
        }
        return .ok(n)
    }

    private func readArg(_ keys: [Key], _ i: inout Int) -> Step<Character> {
        guard i < keys.count else { return .incomplete }
        let k = keys[i]
        i += 1
        switch k {
        case .char(let c): return .ok(c)
        case .tab: return .ok("\t")
        case .enter: return .ok("\n")
        default: return .invalid
        }
    }

    private func parse(_ keys: [Key]) -> Step<Cmd> {
        var i = 0
        var cmd = Cmd()
        if keys.first == .char("\"") {
            i = 1
            guard i < keys.count else { return .incomplete }
            guard case .char(let r) = keys[i], ViEngine.isRegisterName(r) else { return .invalid }
            cmd.register = r
            i += 1
        }
        let c1 = parseCount(keys, &i)
        let ns = readName(keys, &i)
        guard case .ok(let name) = ns else { return ns.failed }

        if isVisual {
            if name == "i" || name == "a" {
                let a = readArg(keys, &i)
                guard case .ok(let o) = a else { return a.failed }
                cmd.name = "textobj"; cmd.count = c1
                cmd.motion = MotionSpec(name: name, arg: o)
                return .ok(cmd)
            }
            if ViEngine.visualCommands.contains(name) {
                cmd.name = name; cmd.count = c1
                if name == "r" {
                    let a = readArg(keys, &i)
                    guard case .ok(let c) = a else { return a.failed }
                    cmd.arg = c
                }
                return .ok(cmd)
            }
        } else if ViEngine.operators.contains(name) {
            cmd.name = name
            let c2 = parseCount(keys, &i)
            if c1 != nil || c2 != nil { cmd.count = (c1 ?? 1) * (c2 ?? 1) }
            guard i < keys.count else { return .incomplete }
            let opLast = name.last!
            if keys[i] == .char(opLast) {
                cmd.motion = MotionSpec(name: "_line")
                return .ok(cmd)
            }
            if name.count == 2 && keys[i] == .char("g") {
                guard i + 1 < keys.count else { return .incomplete }
                if keys[i + 1] == .char(opLast) { cmd.motion = MotionSpec(name: "_line"); return .ok(cmd) }
            }
            if keys[i] == .char("i") || keys[i] == .char("a") {
                let t = keys[i] == .char("i") ? "i" : "a"
                i += 1
                let a = readArg(keys, &i)
                guard case .ok(let o) = a else { return a.failed }
                guard "wWp\"'`()b{}B[]<>".contains(o) else { return .invalid }
                cmd.motion = MotionSpec(name: t, arg: o)
                return .ok(cmd)
            }
            let ms = readName(keys, &i)
            guard case .ok(let mname) = ms else { return ms.failed }
            if mname == "/" || mname == "?" { cmd.motion = MotionSpec(name: mname); return .ok(cmd) }
            guard ViEngine.motionNames.contains(mname) else { return .invalid }
            var m = MotionSpec(name: mname)
            if ViEngine.argMotions.contains(mname) {
                let a = readArg(keys, &i)
                guard case .ok(let c) = a else { return a.failed }
                m.arg = c
            }
            cmd.motion = m
            return .ok(cmd)
        }

        cmd.name = name
        cmd.count = c1
        if ViEngine.motionNames.contains(name) {
            if ViEngine.argMotions.contains(name) {
                let a = readArg(keys, &i)
                guard case .ok(let c) = a else { return a.failed }
                cmd.arg = c
            }
            return .ok(cmd)
        }
        if ViEngine.scrollCommands.contains(name) { return .ok(cmd) }
        if isVisual { return .invalid }
        if name == "q" && recordingRegister != nil { return .ok(cmd) }
        if ViEngine.argCommands.contains(name) {
            let a = readArg(keys, &i)
            guard case .ok(let c) = a else { return a.failed }
            cmd.arg = c
            return .ok(cmd)
        }
        if ViEngine.normalCommands.contains(name) { return .ok(cmd) }
        return .invalid
    }

    private func normalKey(_ key: Key) {
        if key == .escape || key == .ctrl("[") || key == .ctrl("c") {
            if !pendingKeys.isEmpty { pendingKeys = []; return }
            if isVisual { exitVisual(); return }
            bell()
            return
        }
        pendingKeys.append(key)
        switch parse(pendingKeys) {
        case .incomplete: return
        case .invalid:
            pendingKeys = []
            bell()
        case .ok(let cmd):
            pendingKeys = []
            if isVisual { executeVisual(cmd) } else { execute(cmd) }
        }
    }

    var showcmd: String { displayKeys(pendingKeys) }

    // MARK: Motions

    private func nextPos(_ p: Pos) -> Pos? {
        if p.col < lines[p.row].count { return Pos(p.row, p.col + 1) }
        if p.row + 1 < lines.count { return Pos(p.row + 1, 0) }
        return nil
    }
    private func prevPos(_ p: Pos) -> Pos? {
        if p.col > 0 { return Pos(p.row, min(p.col - 1, lines[p.row].count)) }
        if p.row > 0 { return Pos(p.row - 1, lines[p.row - 1].count) }
        return nil
    }

    private func wordForward(_ start: Pos, big: Bool) -> Pos {
        var p = start
        if let ch = charAt(p) {
            let c = charClass(ch, big)
            if c != 0 {
                while p.col < lines[p.row].count && charClass(lines[p.row][p.col], big) == c { p.col += 1 }
            }
        }
        while true {
            if p.col >= lines[p.row].count {
                if p.row + 1 >= lines.count { return Pos(p.row, lines[p.row].count) }
                p = Pos(p.row + 1, 0)
                if lines[p.row].isEmpty { return p }
                continue
            }
            if charClass(lines[p.row][p.col], big) == 0 { p.col += 1; continue }
            return p
        }
    }

    private func wordEnd(_ start: Pos, big: Bool) -> Pos {
        guard var p = nextPos(start) else { return start }
        while charAt(p) == nil || charClass(charAt(p)!, big) == 0 {
            guard let n = nextPos(p) else { return p }
            p = n
        }
        let c = charClass(charAt(p)!, big)
        while p.col + 1 < lines[p.row].count && charClass(lines[p.row][p.col + 1], big) == c { p.col += 1 }
        return p
    }

    private func endOfCurrentWord(_ p: Pos, big: Bool) -> Pos {
        guard let ch = charAt(p) else { return p }
        let c = charClass(ch, big)
        var q = p
        while q.col + 1 < lines[q.row].count && charClass(lines[q.row][q.col + 1], big) == c { q.col += 1 }
        return q
    }

    private func wordBackward(_ start: Pos, big: Bool) -> Pos {
        guard var p = prevPos(start) else { return start }
        while true {
            if lines[p.row].isEmpty { return p }
            if let ch = charAt(p), charClass(ch, big) != 0 { break }
            guard let pr = prevPos(p) else { return p }
            p = pr
        }
        let c = charClass(charAt(p)!, big)
        while p.col > 0 && charClass(lines[p.row][p.col - 1], big) == c { p.col -= 1 }
        return p
    }

    private func wordEndBackward(_ start: Pos, big: Bool) -> Pos {
        var p = start
        if let ch = charAt(p) {
            let c = charClass(ch, big)
            if c != 0 { while p.col > 0 && charClass(lines[p.row][p.col - 1], big) == c { p.col -= 1 } }
        }
        guard var q = prevPos(p) else { return Pos(0, 0) }
        while true {
            if lines[q.row].isEmpty { return q }
            if let ch = charAt(q), charClass(ch, big) != 0 { return q }
            guard let r = prevPos(q) else { return q }
            q = r
        }
    }

    private func paragraphForward(_ row: Int) -> Pos {
        var r = row
        while r < lastRow && lines[r].isEmpty { r += 1 }
        while r < lastRow && !lines[r].isEmpty { r += 1 }
        if r == lastRow && !lines[r].isEmpty { return Pos(r, lines[r].count) }
        return Pos(r, 0)
    }
    private func paragraphBackward(_ row: Int) -> Pos {
        var r = row
        while r > 0 && lines[r].isEmpty { r -= 1 }
        while r > 0 && !lines[r].isEmpty { r -= 1 }
        return Pos(r, 0)
    }

    private func findChar(_ name: Character, _ c: Character, count: Int, from p: Pos, isRepeat: Bool) -> Pos? {
        let line = lines[p.row]
        var col = p.col
        let forward = name == "f" || name == "t"
        for k in 0..<count {
            if forward {
                var start = col + 1
                if name == "t" && isRepeat && k == 0 && start < line.count && line[start] == c { start += 1 }
                guard start < line.count, let idx = (start..<line.count).first(where: { line[$0] == c }) else { return nil }
                col = idx
            } else {
                var start = col - 1
                if name == "T" && isRepeat && k == 0 && start >= 0 && line[start] == c { start -= 1 }
                guard start >= 0, let idx = (0...start).last(where: { line[$0] == c }) else { return nil }
                col = idx
            }
        }
        if name == "t" { col -= 1 } else if name == "T" { col += 1 }
        return Pos(p.row, col)
    }

    private static let bracketPairs: [Character: (Character, Bool)] = [
        "(": (")", true), "[": ("]", true), "{": ("}", true), ")": ("(", false), "]": ("[", false), "}": ("{", false),
    ]

    /// Starting at `p` (exclusive), scan for the `close` that balances `open`.
    private func scanMatch(from p: Pos, open: Character, close: Character, forward: Bool) -> Pos? {
        var depth = 0
        var r = p.row, c = p.col
        while true {
            if forward {
                c += 1
                while c >= lines[r].count { r += 1; if r >= lines.count { return nil }; c = 0 }
            } else {
                c -= 1
                while c < 0 { r -= 1; if r < 0 { return nil }; c = lines[r].count - 1 }
            }
            let ch = lines[r][c]
            if ch == open { depth += 1 } else if ch == close {
                if depth == 0 { return Pos(r, c) }
                depth -= 1
            }
        }
    }

    private func matchPair(at p: Pos) -> Pos? {
        let line = lines[p.row]
        guard p.col < line.count, let col = (p.col..<line.count).first(where: { ViEngine.bracketPairs[line[$0]] != nil }) else { return nil }
        let ch = line[col]
        let (other, fwd) = ViEngine.bracketPairs[ch]!
        return scanMatch(from: Pos(p.row, col), open: ch, close: other, forward: fwd)
    }

    private func computeMotion(_ m: MotionSpec, count: Int?, from p: Pos, forOp: Bool) -> (Pos, MotionKind)? {
        let n = count ?? 1
        let len = lines[p.row].count
        let allowEnd = mode == .insert
        switch m.name {
        case "h":
            if p.col == 0 { return nil }
            return (Pos(p.row, max(0, p.col - n)), .exclusive)
        case "l":
            if forOp {
                if len == 0 { return nil }
                return (Pos(p.row, min(len, p.col + n)), .exclusive)
            }
            if p.col >= len - 1 { return nil }
            return (Pos(p.row, min(len - 1, p.col + n)), .exclusive)
        case "j", "gj":
            if p.row >= lastRow { return nil }
            let r = min(lastRow, p.row + n)
            return (Pos(r, colFor(r, curswant, allowEnd: allowEnd)), .linewise)
        case "k", "gk":
            if p.row == 0 { return nil }
            let r = max(0, p.row - n)
            return (Pos(r, colFor(r, curswant, allowEnd: allowEnd)), .linewise)
        case "+", "<CR>":
            if p.row + n > lastRow { return nil }
            return (Pos(p.row + n, firstNonBlank(p.row + n)), .linewise)
        case "-":
            if p.row - n < 0 { return nil }
            return (Pos(p.row - n, firstNonBlank(p.row - n)), .linewise)
        case "_":
            let r = min(lastRow, p.row + n - 1)
            return (Pos(r, firstNonBlank(r)), .linewise)
        case "0", "g0": return (Pos(p.row, 0), .exclusive)
        case "^", "g^": return (Pos(p.row, firstNonBlank(p.row)), .exclusive)
        case "$", "g$":
            let r = min(lastRow, p.row + n - 1)
            return (Pos(r, max(0, lines[r].count - 1)), .inclusive)
        case "g_":
            let r = min(lastRow, p.row + n - 1)
            let l = lines[r]
            return (Pos(r, max(0, (l.lastIndex(where: { !isBlank($0) }) ?? 0))), .inclusive)
        case "gm": return (Pos(p.row, colFor(p.row, visibleCols / 2)), .exclusive)
        case "|": return (Pos(p.row, colFor(p.row, n - 1)), .exclusive)
        case "w", "W":
            let big = m.name == "W"
            var q = p
            for _ in 0..<n { q = wordForward(q, big: big) }
            if q == p && !forOp { return nil }
            if forOp && q.row > p.row && q.col <= firstNonBlankStrict(q.row) {
                q = Pos(q.row - 1, lines[q.row - 1].count)
                if q < p { q = p }
            }
            return (q, .exclusive)
        case "b", "B":
            var q = p
            for _ in 0..<n { q = wordBackward(q, big: m.name == "B") }
            if q == p { return nil }
            return (q, .exclusive)
        case "e", "E":
            var q = p
            for _ in 0..<n { q = wordEnd(q, big: m.name == "E") }
            if q == p && !forOp { return nil }
            return (q, .inclusive)
        case "ge", "gE":
            var q = p
            for _ in 0..<n { q = wordEndBackward(q, big: m.name == "gE") }
            return (q, .inclusive)
        case "gg", "G":
            var r = m.name == "gg" ? (count ?? 1) - 1 : (count.map { $0 - 1 } ?? lastRow)
            r = max(0, min(lastRow, r))
            return (Pos(r, firstNonBlank(r)), .linewise)
        case "f", "F", "t", "T":
            guard let c = m.arg else { return nil }
            let nm = m.name.first!
            lastFind = (nm, c)
            guard let q = findChar(nm, c, count: n, from: p, isRepeat: false) else { return nil }
            return (q, nm == "f" || nm == "t" ? .inclusive : .exclusive)
        case ";", ",":
            guard let (nm0, c) = lastFind else { return nil }
            var nm = nm0
            if m.name == "," {
                let flip: [Character: Character] = ["f": "F", "F": "f", "t": "T", "T": "t"]
                nm = flip[nm0]!
            }
            guard let q = findChar(nm, c, count: n, from: p, isRepeat: true) else { return nil }
            return (q, nm == "f" || nm == "t" ? .inclusive : .exclusive)
        case "%":
            if let c = count {
                let r = max(0, min(lastRow, (c * lines.count + 99) / 100 - 1))
                return (Pos(r, firstNonBlank(r)), .linewise)
            }
            guard let q = matchPair(at: p) else { return nil }
            return (q, .inclusive)
        case "H":
            let bottom = min(lastRow, topLine + visibleRows - 1)
            let r = min(bottom, topLine + n - 1)
            return (Pos(r, firstNonBlank(r)), .linewise)
        case "L":
            let bottom = min(lastRow, topLine + visibleRows - 1)
            let r = max(topLine, bottom - (n - 1))
            return (Pos(r, firstNonBlank(r)), .linewise)
        case "M":
            let shown = min(visibleRows, lines.count - topLine)
            let r = topLine + max(0, shown - 1) / 2
            return (Pos(r, firstNonBlank(r)), .linewise)
        case "}":
            var q = p
            for _ in 0..<n { q = paragraphForward(q.row == p.row && q == p ? p.row : q.row) }
            if !forOp && q.col > 0 { q.col = max(0, lines[q.row].count - 1) }
            return (q, .exclusive)
        case "{":
            var q = p
            for _ in 0..<n { q = paragraphBackward(q.row) }
            return (q, .exclusive)
        case "n", "N":
            guard let pat = lastSearch else { setError("E35: No previous regular expression"); return nil }
            let fwd = (m.name == "n") == lastSearchForward
            guard let q = searchRepeated(pat, forward: fwd, from: p, count: n) else { return nil }
            return (q, .exclusive)
        case "*", "#":
            guard let (word, start) = wordUnderCursor(p) else { setError("E348: No string under cursor"); return nil }
            let isKeyword = word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            let esc = escapeVim(word)
            let pat = isKeyword ? "\\<" + esc + "\\>" : esc
            lastSearch = pat
            lastSearchForward = m.name == "*"
            hlsearchActive = true
            pushHistory(&searchHistory, pat)
            let from = Pos(p.row, start)
            guard let q = searchRepeated(pat, forward: lastSearchForward, from: from, count: n) else { return nil }
            setMessage((lastSearchForward ? "/" : "?") + pat)
            return (q, .exclusive)
        case "'", "`":
            guard let mk = m.arg, let mp = markPos(mk) else { setError("E20: Mark not set"); return nil }
            let r = max(0, min(lastRow, mp.row))
            if m.name == "'" { return (Pos(r, firstNonBlank(r)), .linewise) }
            return (Pos(r, min(mp.col, lines[r].count)), .exclusive)
        default:
            return nil
        }
    }

    private func markPos(_ m: Character) -> Pos? {
        if m == "`" || m == "'" { return marks["'"] ?? Pos(0, 0) }
        return marks[m.isUppercase ? Character(m.lowercased()) : m]
    }

    private func wordUnderCursor(_ p: Pos) -> (String, Int)? {
        let line = lines[p.row]
        guard !line.isEmpty else { return nil }
        let isKw: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        var c = p.col
        if c >= line.count || !isKw(line[c]) {
            guard let j = (c..<line.count).first(where: { isKw(line[$0]) }) else {
                // fall back to non-blank sequence
                guard c < line.count, !isBlank(line[c]) else { return nil }
                var s = c, e = c
                while s > 0 && !isBlank(line[s - 1]) { s -= 1 }
                while e + 1 < line.count && !isBlank(line[e + 1]) { e += 1 }
                return (String(line[s...e]), s)
            }
            c = j
        }
        var s = c, e = c
        while s > 0 && isKw(line[s - 1]) { s -= 1 }
        while e + 1 < line.count && isKw(line[e + 1]) { e += 1 }
        return (String(line[s...e]), s)
    }

    private func setJumpMark() { marks["'"] = cursor }

    private func doMotion(_ cmd: Cmd) {
        let wasLastFind = lastFind
        guard let (target, _) = computeMotion(MotionSpec(name: cmd.name, arg: cmd.arg), count: cmd.count, from: cursor, forOp: false) else {
            if cmd.name == ";" || cmd.name == "," { lastFind = wasLastFind }
            if !messageIsError || message.isEmpty { bell() }
            return
        }
        if ViEngine.jumpMotions.contains(cmd.name) && target.row != cursor.row || cmd.name == "`" || cmd.name == "'" {
            let old = cursor
            cursor = target
            marks["'"] = old
        } else {
            cursor = target
        }
        let len = lines[cursor.row].count
        cursor.col = min(cursor.col, max(0, len - 1))
        switch cmd.name {
        case "j", "k", "gj", "gk": break
        case "$", "g$": curswant = Int.max
        default: updateCurswant()
        }
    }

    // MARK: Text objects

    private func textObject(_ type: Character, _ obj: Character, at p: Pos) -> TextRange? {
        let row = p.row
        let line = lines[row]
        let len = line.count
        switch obj {
        case "w", "W":
            guard len > 0 else { return nil }
            let big = obj == "W"
            let pc = min(p.col, len - 1)
            let c = charClass(line[pc], big)
            var s = pc, e = pc
            while s > 0 && charClass(line[s - 1], big) == c { s -= 1 }
            while e + 1 < len && charClass(line[e + 1], big) == c { e += 1 }
            if type == "a" {
                if c != 0 {
                    var e2 = e
                    while e2 + 1 < len && isBlank(line[e2 + 1]) { e2 += 1 }
                    if e2 > e { e = e2 } else { while s > 0 && isBlank(line[s - 1]) { s -= 1 } }
                } else if e + 1 < len {
                    let c2 = charClass(line[e + 1], big)
                    e += 1
                    while e + 1 < len && charClass(line[e + 1], big) == c2 { e += 1 }
                }
            }
            return TextRange(start: Pos(row, s), end: Pos(row, e + 1), linewise: false)
        case "\"", "'", "`":
            var idx: [Int] = []
            for (j, ch) in line.enumerated() where ch == obj {
                if j > 0 && line[j - 1] == "\\" { continue }
                idx.append(j)
            }
            var pair: (Int, Int)?
            var k = 0
            while k + 1 < idx.count {
                if p.col >= idx[k] && p.col <= idx[k + 1] { pair = (idx[k], idx[k + 1]); break }
                k += 2
            }
            if pair == nil {
                k = 0
                while k + 1 < idx.count { if idx[k] > p.col { pair = (idx[k], idx[k + 1]); break }; k += 2 }
            }
            guard let (a, b) = pair else { return nil }
            if type == "i" { return TextRange(start: Pos(row, a + 1), end: Pos(row, b), linewise: false) }
            var s = a, e = b + 1
            if e < len && isBlank(line[e]) { while e < len && isBlank(line[e]) { e += 1 } }
            else { while s > 0 && isBlank(line[s - 1]) { s -= 1 } }
            return TextRange(start: Pos(row, s), end: Pos(row, e), linewise: false)
        case "(", ")", "b", "{", "}", "B", "[", "]", "<", ">":
            let (open, close): (Character, Character)
            switch obj {
            case "(", ")", "b": (open, close) = ("(", ")")
            case "{", "}", "B": (open, close) = ("{", "}")
            case "[", "]": (open, close) = ("[", "]")
            default: (open, close) = ("<", ">")
            }
            let o: Pos?
            if charAt(p) == open { o = p } else { o = scanMatch(from: p, open: close, close: open, forward: false) }
            guard let op = o, let cl = scanMatch(from: op, open: open, close: close, forward: true) else { return nil }
            if type == "a" { return TextRange(start: op, end: Pos(cl.row, cl.col + 1), linewise: false) }
            var s = Pos(op.row, op.col + 1)
            if s.col >= lines[op.row].count && cl.row > op.row {
                if lines[cl.row][..<cl.col].allSatisfy(isBlank) {
                    if cl.row - op.row >= 2 { return TextRange(start: Pos(op.row + 1, 0), end: Pos(cl.row - 1, 0), linewise: true) }
                    return TextRange(start: cl, end: cl, linewise: false)
                }
                s = Pos(op.row + 1, 0)
            }
            return TextRange(start: s, end: cl, linewise: false)
        case "p":
            let blank: (Int) -> Bool = { self.lines[$0].allSatisfy(isBlank) }
            let b = blank(row)
            var s = row, e = row
            while s > 0 && blank(s - 1) == b { s -= 1 }
            while e < lastRow && blank(e + 1) == b { e += 1 }
            if type == "a" {
                if e < lastRow {
                    let b2 = blank(e + 1)
                    e += 1
                    while e < lastRow && blank(e + 1) == b2 { e += 1 }
                } else if s > 0 {
                    let b2 = blank(s - 1)
                    s -= 1
                    while s > 0 && blank(s - 1) == b2 { s -= 1 }
                }
            }
            return TextRange(start: Pos(s, 0), end: Pos(e, 0), linewise: true)
        default:
            return nil
        }
    }

    // MARK: Operators

    private func normalizeRange(from a: Pos, to b: Pos, kind: MotionKind) -> TextRange {
        let s = min(a, b)
        var e = max(a, b)
        switch kind {
        case .linewise:
            return TextRange(start: Pos(s.row, 0), end: Pos(e.row, 0), linewise: true)
        case .inclusive:
            let len = lines[e.row].count
            return TextRange(start: s, end: Pos(e.row, min(len, e.col + 1)), linewise: false)
        case .exclusive:
            if e.col == 0 && e.row > s.row {
                if s.col <= firstNonBlankStrict(s.row) {
                    return TextRange(start: Pos(s.row, 0), end: Pos(e.row - 1, 0), linewise: true)
                }
                e = Pos(e.row - 1, lines[e.row - 1].count)
            }
            e.col = min(e.col, lines[e.row].count)
            return TextRange(start: s, end: e, linewise: false)
        }
    }

    private func operatorRange(_ cmd: Cmd) -> TextRange? {
        guard let m = cmd.motion else { return nil }
        let n = cmd.count ?? 1
        switch m.name {
        case "_line", "<vl>":
            let last = min(lastRow, cursor.row + n - 1)
            return TextRange(start: Pos(cursor.row, 0), end: Pos(last, 0), linewise: true)
        case "<vc>":
            let len = lines[cursor.row].count
            guard len > 0 else { return nil }
            return TextRange(start: cursor, end: Pos(cursor.row, min(len, cursor.col + n)), linewise: false)
        case "i", "a":
            return textObject(m.name.first!, m.arg!, at: cursor)
        default:
            if cmd.name == "c" && (m.name == "w" || m.name == "W"), let ch = charAt(cursor), !isBlank(ch) {
                let big = m.name == "W"
                var q = endOfCurrentWord(cursor, big: big)
                if n > 1 { for _ in 1..<n { q = wordEnd(q, big: big) } }
                return normalizeRange(from: cursor, to: q, kind: .inclusive)
            }
            guard let (t, kind) = computeMotion(m, count: cmd.count, from: cursor, forOp: true) else { return nil }
            if ViEngine.jumpMotions.contains(m.name) { setJumpMark() }
            return normalizeRange(from: cursor, to: t, kind: kind)
        }
    }

    private var pendingSearchOperator: Cmd?

    private func applyOperator(_ cmd: Cmd) {
        if let m = cmd.motion, m.name == "/" || m.name == "?" {
            pendingSearchOperator = cmd
            startCmdline(m.name.first!)
            return
        }
        guard let r = operatorRange(cmd) else {
            if !messageIsError || message.isEmpty { bell() }
            return
        }
        applyOp(cmd.name, r, register: cmd.register, count: 1)
    }

    private func reportLines(_ n: Int, _ what: String) {
        if n > 2 { setMessage("\(n) \(what)") }
    }

    private func applyOp(_ op: String, _ r: TextRange, register: Character?, count: Int) {
        switch op {
        case "y":
            let content = extract(r)
            storeRegister(register, content, isDelete: false)
            if r.linewise {
                if r.start.row < cursor.row { cursor.row = r.start.row }
                reportLines(r.end.row - r.start.row + 1, "lines yanked")
            } else {
                cursor = r.start
            }
            updateCurswant()
        case "d":
            let content = extract(r)
            storeRegister(register, content, isDelete: true)
            deleteRange(r)
            if r.linewise {
                let row = min(r.start.row, lastRow)
                cursor = Pos(row, firstNonBlank(row))
                reportLines(r.end.row - r.start.row + 1, "fewer lines")
            } else {
                cursor = r.start
            }
            clampCursor()
            updateCurswant()
        case "c":
            let content = extract(r)
            storeRegister(register, content, isDelete: true)
            if r.linewise {
                let indent: [Character] = opts.autoindent ? leadingWS(r.start.row) : []
                setLine(r.start.row, indent)
                removeLines((r.start.row + 1)..<(r.end.row + 1))
                startInsert(at: Pos(r.start.row, indent.count))
            } else {
                deleteRange(r)
                startInsert(at: r.start)
            }
        case "<", ">":
            let rows = r.start.row...(r.linewise ? r.end.row : (r.end.col == 0 && r.end.row > r.start.row ? r.end.row - 1 : r.end.row))
            shiftLines(rows, by: (op == ">" ? 1 : -1) * count)
            cursor = Pos(r.start.row, firstNonBlank(r.start.row))
            updateCurswant()
            let n = rows.count
            if n > 2 { setMessage("\(n) lines \(op)ed 1 time") }
        case "g~", "gu", "gU":
            let rr = r.linewise ? TextRange(start: Pos(r.start.row, 0), end: Pos(r.end.row, lines[r.end.row].count), linewise: false) : r
            for row in rr.start.row...rr.end.row {
                let from = row == rr.start.row ? rr.start.col : 0
                let to = row == rr.end.row ? rr.end.col : lines[row].count
                guard from < to else { continue }
                var l = lines[row]
                for i in from..<to {
                    switch op {
                    case "gu": l[i] = String(l[i]).lowercased().count == 1 ? Character(String(l[i]).lowercased()) : l[i]
                    case "gU": l[i] = String(l[i]).uppercased().count == 1 ? Character(String(l[i]).uppercased()) : l[i]
                    default: l[i] = toggledCase(l[i])
                    }
                }
                setLine(row, l)
            }
            cursor = r.linewise ? Pos(r.start.row, 0) : r.start
            updateCurswant()
        default: break
        }
    }

    private func shiftLines(_ rows: ClosedRange<Int>, by levels: Int) {
        for r in rows {
            let line = lines[r]
            if line.isEmpty { continue }
            let ws = line.prefix(while: isBlank)
            var w = 0
            for c in ws { w += c == "\t" ? ts - w % ts : 1 }
            let nw = max(0, (levels > 0 ? (w / sw + levels) : ((w + sw - 1) / sw + levels)) * sw)
            setLine(r, makeIndent(nw) + Array(line[ws.count...]))
        }
    }

    private func makeIndent(_ w: Int) -> [Character] {
        if opts.expandtab { return Array(repeating: " ", count: w) }
        return Array(repeating: "\t", count: w / ts) + Array(repeating: " ", count: w % ts)
    }

    // MARK: Registers

    private func storeRegister(_ reg: Character?, _ content: RegisterContent, isDelete: Bool) {
        if reg == "_" { return }
        if let r = reg, r != "\"" {
            if r == "+" || r == "*" {
                clipboardSet?(content.text)
            } else if r.isUppercase {
                let lr = Character(r.lowercased())
                if var ex = registers[lr] {
                    if ex.linewise || content.linewise {
                        ex.lines += content.lines
                        ex.linewise = true
                    } else {
                        ex.lines[ex.lines.count - 1] += content.lines[0]
                        ex.lines += content.lines.dropFirst()
                    }
                    registers[lr] = ex
                } else {
                    registers[lr] = content
                }
            } else {
                registers[r] = content
            }
        } else {
            if isDelete {
                if content.linewise || content.lines.count > 1 {
                    for k in stride(from: 9, to: 1, by: -1) {
                        registers[Character(String(k))] = registers[Character(String(k - 1))]
                    }
                    registers["1"] = content
                } else {
                    registers["-"] = content
                }
            } else {
                registers["0"] = content
            }
            if opts.clipboard.contains("unnamed") { clipboardSet?(content.text) }
        }
        registers["\""] = content
    }

    private func getRegister(_ r: Character?) -> RegisterContent? {
        var name = r ?? "\""
        if name == "\"" && opts.clipboard.contains("unnamed") { name = "+" }
        switch name {
        case "+", "*":
            guard let s = clipboardGet?(), !s.isEmpty else { return registers["\""] }
            return RegisterContent.from(s)
        case "%": return filePath.map { _ in RegisterContent(lines: [Array(displayName)], linewise: false) }
        case ":": return lastExCommand.map { RegisterContent(lines: [Array($0)], linewise: false) }
        case "/": return lastSearch.map { RegisterContent(lines: [Array($0)], linewise: false) }
        case ".": return RegisterContent.from(lastInserted)
        default:
            if name.isUppercase { name = Character(name.lowercased()) }
            return registers[name]
        }
    }

    private func put(_ reg: Character?, before: Bool, count: Int, cursorAfter: Bool = false) {
        guard let content = getRegister(reg) else {
            setError("E353: Nothing in register \(reg.map { String($0) } ?? "\"")")
            return
        }
        if content.linewise {
            var block: [[Character]] = []
            for _ in 0..<count { block += content.lines }
            let at = before ? cursor.row : cursor.row + 1
            insertLines(block, at: at)
            if cursorAfter { cursor = Pos(min(lastRow, at + block.count), 0) }
            else { cursor = Pos(at, firstNonBlank(at)) }
            reportLines(block.count, "more lines")
        } else {
            var parts = content.lines
            if count > 1 {
                let one = parts
                for _ in 1..<count {
                    parts[parts.count - 1] += one[0]
                    parts += one.dropFirst()
                }
            }
            let len = lines[cursor.row].count
            let col = before ? min(cursor.col, len) : min(cursor.col + 1, len)
            let end = insertText(parts, at: Pos(cursor.row, col))
            if cursorAfter { cursor = end }
            else if parts.count == 1 { cursor = Pos(cursor.row, max(col, end.col - 1)) }
            else { cursor = Pos(cursor.row, col) }
        }
        updateCurswant()
    }

    // MARK: Normal-mode commands

    private func opWith(_ cmd: Cmd, _ op: String, _ motion: String) {
        var c = cmd
        c.name = op
        c.motion = MotionSpec(name: motion)
        applyOperator(c)
    }

    private func execute(_ cmd: Cmd) {
        let n = cmd.count ?? 1
        if ViEngine.motionNames.contains(cmd.name) { doMotion(cmd); return }
        if ViEngine.scrollCommands.contains(cmd.name) { scrollCommand(cmd); return }
        let isChange = ViEngine.changeCommands.contains(cmd.name)
        if ViEngine.operators.contains(cmd.name) {
            applyOperator(cmd)
        } else {
            switch cmd.name {
            case "x": if lines[cursor.row].isEmpty { return }; opWith(cmd, "d", "l")
            case "X": opWith(cmd, "d", "h")
            case "D": opWith(cmd, "d", "$")
            case "C": opWith(cmd, "c", "$")
            case "s":
                if lines[cursor.row].isEmpty { startInsert(at: cursor) } else { opWith(cmd, "c", "l") }
            case "S": opWith(cmd, "c", "_line")
            case "Y": opWith(cmd, "y", "_line")
            case "p", "P", "gp", "gP":
                put(cmd.register, before: cmd.name.hasSuffix("P"), count: n, cursorAfter: cmd.name.hasPrefix("g"))
            case "J", "gJ": joinLines(cursor.row, count: max(2, n), spaces: cmd.name == "J")
            case "r":
                guard let c = cmd.arg else { return }
                replaceChars(c, count: n)
            case "R": startInsert(at: cursor, replace: true)
            case "~":
                let len = lines[cursor.row].count
                guard len > 0 else { return }
                var l = lines[cursor.row]
                let end = min(len, cursor.col + n)
                for i in cursor.col..<end { l[i] = toggledCase(l[i]) }
                setLine(cursor.row, l)
                cursor.col = min(len - 1, end)
                updateCurswant()
            case "u": undo(n)
            case "U": undo(1)
            case "^r": redo(n)
            case ".": repeatLastChange(count: cmd.count)
            case "v": visualAnchor = cursor; mode = .visual
            case "V": visualAnchor = cursor; mode = .visualLine
            case ":": startCmdline(":", prefill: cmd.count.map { $0 == 1 ? "." : ".,.+\($0 - 1)" } ?? "")
            case "/", "?": startCmdline(cmd.name.first!)
            case "i": startInsert(at: cursor, count: n)
            case "a": startInsert(at: Pos(cursor.row, min(lines[cursor.row].count, cursor.col + 1)), count: n)
            case "I": startInsert(at: Pos(cursor.row, firstNonBlankStrict(cursor.row)), count: n)
            case "gI": startInsert(at: Pos(cursor.row, 0), count: n)
            case "A": startInsert(at: Pos(cursor.row, lines[cursor.row].count), count: n)
            case "gi":
                let p = marks["^"] ?? cursor
                startInsert(at: Pos(min(p.row, lastRow), p.col), count: n)
            case "o", "O":
                openLine(below: cmd.name == "o")
                startInsert(at: cursor, count: n, openLine: true)
            case "m":
                guard let c = cmd.arg else { return }
                if c.isLetter || c == "'" || c == "`" || c == "<" || c == ">" {
                    marks[c == "`" ? "'" : (c.isUppercase ? Character(c.lowercased()) : c)] = cursor
                } else { bell() }
            case "q":
                if let reg = recordingRegister {
                    if !recordBuffer.isEmpty { recordBuffer.removeLast() }
                    let content = RegisterContent(lines: [Array(keysToRegisterString(recordBuffer))], linewise: false)
                    storeRegister(reg, content, isDelete: false)
                    recordingRegister = nil
                    recordBuffer = []
                } else if let c = cmd.arg, c.isLetter || c.isNumber || c == "\"" {
                    recordingRegister = c
                    recordBuffer = []
                } else { bell() }
            case "@":
                guard var r = cmd.arg else { return }
                if r == "@" { guard let lm = lastMacro else { setError("E748: No previously used register"); return }; r = lm }
                if r == ":" {
                    guard let ex = lastExCommand else { setError("E30: No previous command line"); return }
                    for _ in 0..<n { runEx(ex) }
                    return
                }
                guard depth < 60 else { return }
                guard let content = getRegister(r) else { setError("E748: No previously used register"); return }
                lastMacro = r
                let keys = registerStringToKeys(content.text)
                for _ in 0..<n { for k in keys { feed(k) } }
            case "ZZ": runEx("x")
            case "ZQ": runEx("q!")
            case "^g": showFileInfo()
            case "gv":
                guard let lv = lastVisual else { bell(); return }
                visualAnchor = lv.anchor; cursor = lv.cursor; mode = lv.mode
            case "^a", "^x": increment(cmd.name == "^a" ? n : -n)
            case "&": runEx("s")
            case "^l": break
            default: bell()
            }
        }
        if isChange && !replayingDot && cmd.name != "y" {
            if mode == .insert || mode == .replace { recordingChange = cmd } else { lastChange = (cmd, []) }
        }
    }

    private func repeatLastChange(count: Int?) {
        guard let lc = lastChange else { return }
        var c = lc.cmd
        if let cnt = count { c.count = cnt }
        if let r = c.register, let d = r.wholeNumberValue, d > 0, d < 9 { c.register = Character(String(d + 1)) }
        replayingDot = true
        execute(c)
        if mode == .insert || mode == .replace {
            for k in lc.insertKeys { insertKey(k) }
            insertKey(.escape)
        }
        replayingDot = false
        lastChange = (c, lc.insertKeys)
    }

    private func showFileInfo() {
        let pct = lines.count > 0 ? (cursor.row + 1) * 100 / lines.count : 0
        setMessage("\"\(displayName)\"\(modified ? " [Modified]" : "") \(lines.count) line\(lines.count == 1 ? "" : "s") --\(pct)%--")
    }

    private func replaceChars(_ c: Character, count n: Int) {
        let len = lines[cursor.row].count
        guard cursor.col + n <= len else { bell(); return }
        if c == "\n" {
            var l = lines[cursor.row]
            l.removeSubrange(cursor.col..<(cursor.col + n))
            let tail = Array(l[cursor.col...])
            setLine(cursor.row, Array(l[..<cursor.col]))
            let indent: [Character] = opts.autoindent ? leadingWS(cursor.row) : []
            insertLines([indent + Array(tail.drop(while: isBlank))], at: cursor.row + 1)
            cursor = Pos(cursor.row + 1, indent.count)
        } else {
            var l = lines[cursor.row]
            for i in cursor.col..<(cursor.col + n) { l[i] = c }
            setLine(cursor.row, l)
            cursor.col += n - 1
        }
        updateCurswant()
    }

    private func joinLines(_ row: Int, count: Int, spaces: Bool) {
        let m = min(count - 1, lastRow - row)
        guard m > 0 else { bell(); return }
        var joinCol = 0
        for _ in 0..<m {
            var cur = lines[row]
            var next = lines[row + 1]
            if spaces {
                next = Array(next.drop(while: isBlank))
                if !next.isEmpty && !cur.isEmpty && !isBlank(cur.last!) && next.first != ")" {
                    joinCol = cur.count
                    cur.append(" ")
                } else {
                    joinCol = max(0, cur.count - (next.isEmpty ? 1 : 0))
                }
            } else {
                joinCol = max(0, cur.count - 1)
            }
            setLine(row, cur + next)
            removeLines((row + 1)..<(row + 2))
        }
        cursor = Pos(row, joinCol)
        updateCurswant()
    }

    private func increment(_ delta: Int) {
        var line = lines[cursor.row]
        let len = line.count
        var i = cursor.col
        if i < len && line[i].isASCII && line[i].isNumber {
            while i > 0 && line[i - 1].isASCII && line[i - 1].isNumber { i -= 1 }
        } else {
            guard cursor.col < len, let j = (cursor.col..<len).first(where: { line[$0].isASCII && line[$0].isNumber }) else { bell(); return }
            i = j
        }
        var start = i
        if start > 0 && line[start - 1] == "-" { start -= 1 }
        var end = i
        while end < len && line[end].isASCII && line[end].isNumber { end += 1 }
        guard let v = Int(String(line[start..<end])) else { bell(); return }
        let s = Array(String(v + delta))
        line.replaceSubrange(start..<end, with: s)
        setLine(cursor.row, line)
        cursor.col = start + s.count - 1
        updateCurswant()
    }

    private func openLine(below: Bool) {
        let indent: [Character] = opts.autoindent ? leadingWS(cursor.row) : []
        let row = below ? cursor.row + 1 : cursor.row
        insertLines([indent], at: row)
        cursor = Pos(row, indent.count)
    }

    private func scrollCommand(_ cmd: Cmd) {
        let n = cmd.count ?? 1
        let rows = max(1, visibleRows)
        let so = effectiveScrolloff
        switch cmd.name {
        case "^e":
            topLine = min(lastRow, topLine + n)
            keepCursorInView()
        case "^y":
            topLine = max(0, topLine - n)
            keepCursorInView()
        case "^d", "^u":
            if let c = cmd.count { scrollAmount = c }
            let a = scrollAmount ?? max(1, rows / 2)
            if cmd.name == "^d" {
                if cursor.row == lastRow { bell(); return }
                topLine = max(0, min(topLine + a, lastRow - rows + 1))
                cursor.row = min(lastRow, cursor.row + a)
            } else {
                if cursor.row == 0 { bell(); return }
                topLine = max(0, topLine - a)
                cursor.row = max(0, cursor.row - a)
            }
            cursor.col = firstNonBlank(cursor.row)
            updateCurswant()
        case "^f":
            if topLine >= lastRow { bell(); return }
            topLine = min(lastRow, topLine + max(1, rows - 2) * n)
            cursor.row = min(lastRow, max(cursor.row, topLine + so))
            cursor.col = firstNonBlank(cursor.row)
            updateCurswant()
        case "^b":
            if topLine == 0 { bell(); return }
            topLine = max(0, topLine - max(1, rows - 2) * n)
            cursor.row = min(cursor.row, topLine + rows - 1 - so)
            cursor.col = firstNonBlank(cursor.row)
            updateCurswant()
        case "zz", "z.":
            topLine = max(0, cursor.row - rows / 2)
            if cmd.name == "z." { cursor.col = firstNonBlank(cursor.row) }
        case "zt", "z<CR>":
            topLine = max(0, cursor.row - so)
            if cmd.name == "z<CR>" { cursor.col = firstNonBlank(cursor.row) }
        case "zb", "z-":
            topLine = max(0, cursor.row - rows + 1 + so)
            if cmd.name == "z-" { cursor.col = firstNonBlank(cursor.row) }
        default: break
        }
    }

    // MARK: Visual mode

    func visualRange() -> TextRange {
        let s = min(visualAnchor, cursor), e = max(visualAnchor, cursor)
        if mode == .visualLine { return TextRange(start: Pos(s.row, 0), end: Pos(e.row, 0), linewise: true) }
        let len = lines[e.row].count
        let end: Pos
        if len == 0 || e.col >= len || (e == cursor && curswant == Int.max) {
            end = e.row + 1 < lines.count ? Pos(e.row + 1, 0) : Pos(e.row, len)
        } else {
            end = Pos(e.row, e.col + 1)
        }
        return TextRange(start: Pos(s.row, min(s.col, lines[s.row].count)), end: end, linewise: false)
    }

    private func exitVisual() {
        lastVisual = (visualAnchor, cursor, mode)
        let s = min(visualAnchor, cursor), e = max(visualAnchor, cursor)
        marks["<"] = mode == .visualLine ? Pos(s.row, 0) : s
        marks[">"] = mode == .visualLine ? Pos(e.row, max(0, lines[e.row].count - 1)) : e
        mode = .normal
    }

    private func recordVisualChange(_ op: String, _ r: TextRange, register: Character?) {
        guard !replayingDot else { return }
        var c = Cmd(register: register, name: op)
        if r.linewise {
            c.count = r.end.row - r.start.row + 1
            c.motion = MotionSpec(name: "<vl>")
        } else if r.start.row == r.end.row {
            c.count = r.end.col - r.start.col
            c.motion = MotionSpec(name: "<vc>")
        } else { return }
        if mode == .insert { recordingChange = c } else { lastChange = (c, []) }
    }

    private func executeVisual(_ cmd: Cmd) {
        let n = cmd.count ?? 1
        if ViEngine.motionNames.contains(cmd.name) { doMotion(cmd); return }
        if ViEngine.scrollCommands.contains(cmd.name) { scrollCommand(cmd); return }
        switch cmd.name {
        case "o", "O": swap(&visualAnchor, &cursor); updateCurswant()
        case "v": if mode == .visual { exitVisual() } else { mode = .visual }
        case "V": if mode == .visualLine { exitVisual() } else { mode = .visualLine }
        case "textobj":
            guard let m = cmd.motion, let r = textObject(m.name.first!, m.arg!, at: cursor) else { bell(); return }
            if r.linewise {
                visualAnchor = Pos(r.start.row, 0)
                cursor = Pos(r.end.row, 0)
                mode = .visualLine
            } else {
                guard r.end > r.start else { return }
                visualAnchor = r.start
                var e = r.end
                if e.col == 0 { e = Pos(e.row - 1, lines[e.row - 1].count) } else { e.col -= 1 }
                cursor = e
            }
            updateCurswant()
        case ":":
            exitVisual()
            startCmdline(":", prefill: "'<,'>")
        case "/", "?":
            startCmdline(cmd.name.first!)
        case "gv":
            guard let lv = lastVisual else { bell(); return }
            let cur = (visualAnchor, cursor, mode)
            visualAnchor = lv.anchor; cursor = lv.cursor; mode = lv.mode
            lastVisual = cur
        default:
            var r = visualRange()
            let wasLine = mode == .visualLine
            exitVisual()
            let lw = TextRange(start: Pos(r.start.row, 0), end: Pos(r.end.col == 0 && r.end.row > r.start.row && !wasLine ? r.end.row - 1 : r.end.row, 0), linewise: true)
            switch cmd.name {
            case "d", "x":
                applyOp("d", r, register: cmd.register, count: 1)
                recordVisualChange("d", r, register: cmd.register)
            case "X", "D":
                applyOp("d", lw, register: cmd.register, count: 1)
                recordVisualChange("d", lw, register: cmd.register)
            case "y": applyOp("y", r, register: cmd.register, count: 1); cursor = r.start
            case "Y": applyOp("y", lw, register: cmd.register, count: 1)
            case "c", "s":
                applyOp("c", r, register: cmd.register, count: 1)
                recordVisualChange("c", r, register: cmd.register)
            case "C", "S", "R":
                applyOp("c", lw, register: cmd.register, count: 1)
                recordVisualChange("c", lw, register: cmd.register)
            case "r":
                guard let ch = cmd.arg, ch != "\n" else { return }
                if r.linewise { r = TextRange(start: Pos(r.start.row, 0), end: Pos(r.end.row, lines[r.end.row].count), linewise: false) }
                for row in r.start.row...r.end.row {
                    let from = row == r.start.row ? r.start.col : 0
                    let to = min(lines[row].count, row == r.end.row ? r.end.col : lines[row].count)
                    guard from < to else { continue }
                    var l = lines[row]
                    for i in from..<to { l[i] = ch }
                    setLine(row, l)
                }
                cursor = r.start
            case "~", "u", "U", "g~", "gu", "gU":
                let op = ["~": "g~", "u": "gu", "U": "gU"][cmd.name] ?? cmd.name
                applyOp(op, r, register: nil, count: 1)
                cursor = r.linewise ? Pos(r.start.row, 0) : r.start
                recordVisualChange(op, r, register: nil)
            case ">", "<":
                applyOp(cmd.name, lw, register: nil, count: n)
                recordVisualChange(cmd.name, lw, register: nil)
            case "J", "gJ":
                joinLines(lw.start.row, count: max(2, lw.end.row - lw.start.row + 1), spaces: cmd.name == "J")
            case "p", "P":
                guard let content = getRegister(cmd.register) else { setError("E353: Nothing in register"); return }
                let deleted = extract(r)
                let deletedAll = r.linewise && r.start.row == 0 && r.end.row == lastRow
                deleteRange(r)
                let tmp: Character = "\u{1}"
                registers[tmp] = content
                if r.linewise {
                    if deletedAll {
                        cursor = Pos(0, 0)
                        if content.linewise {
                            put(tmp, before: true, count: n)
                            removeLines(lastRow..<lines.count)
                            cursor = Pos(0, firstNonBlank(0))
                        } else {
                            put(tmp, before: true, count: n)
                        }
                    } else if !content.linewise {
                        let at = min(r.start.row, lines.count)
                        insertLines([[]], at: at)
                        cursor = Pos(at, 0)
                        put(tmp, before: true, count: n)
                    } else if r.start.row > lastRow {
                        cursor = Pos(lastRow, 0)
                        put(tmp, before: false, count: n)
                    } else {
                        cursor = Pos(r.start.row, 0)
                        put(tmp, before: true, count: n)
                    }
                } else {
                    cursor = r.start
                    put(tmp, before: true, count: n)
                }
                registers[tmp] = nil
                if cmd.name == "p" { storeRegister(nil, deleted, isDelete: true) }
            case "I":
                startInsert(at: r.linewise ? Pos(r.start.row, firstNonBlankStrict(r.start.row)) : r.start)
            case "A":
                if r.linewise { startInsert(at: Pos(r.end.row, lines[r.end.row].count)) }
                else { startInsert(at: r.end.col == 0 && r.end.row > r.start.row ? Pos(r.end.row - 1, lines[r.end.row - 1].count) : r.end) }
            default: bell()
            }
        }
    }

    // MARK: Insert mode

    private func startInsert(at p: Pos, count: Int = 1, openLine: Bool = false, replace: Bool = false) {
        mode = replace ? .replace : .insert
        cursor = p
        insertStart = p
        insertKeys = []
        insertRepeat = count
        insertOpenLine = openLine
        replaceOriginals = []
        recordingChange = nil
    }

    private func insertKey(_ key: Key) {
        if insertCtrlR {
            insertCtrlR = false
            if captureInsert { insertKeys.append(key) }
            if case .char(let r) = key, let c = getRegister(r) {
                var parts = c.lines
                if c.linewise { parts.append([]) }
                cursor = insertText(parts, at: cursor)
            }
            return
        }
        let isEsc = key == .escape || key == .ctrl("[") || key == .ctrl("c")
        if captureInsert && !isEsc { insertKeys.append(key) }
        let row = cursor.row
        switch key {
        case _ where isEsc:
            finishInsert()
        case .enter, .ctrl("j"), .ctrl("m"):
            let line = lines[row]
            let c = min(cursor.col, line.count)
            var indent: [Character] = opts.autoindent ? Array(line.prefix(while: isBlank)) : []
            if indent.count > c { indent = Array(indent.prefix(c)) }
            var before = Array(line[..<c])
            // Remove auto-indent that was never typed on.
            if before.allSatisfy(isBlank) && opts.autoindent && c == line.count { before = [] }
            setLine(row, before)
            insertLines([indent + Array(line[c...])], at: row + 1)
            cursor = Pos(row + 1, indent.count)
            replaceOriginals = []
        case .backspace, .ctrl("h"):
            if mode == .replace {
                if let orig = replaceOriginals.popLast(), cursor.col > 0 {
                    cursor.col -= 1
                    var l = lines[row]
                    if let o = orig { l[cursor.col] = o } else { l.remove(at: cursor.col) }
                    setLine(row, l)
                } else if cursor.col > 0 { cursor.col -= 1 }
            } else if cursor.col > 0 {
                var c = cursor.col - 1
                // softtabstop-style backspace over expanded spaces
                if opts.expandtab, opts.softtabstop > 0, lines[row][..<cursor.col].allSatisfy({ $0 == " " }) {
                    c = ((cursor.col - 1) / opts.softtabstop) * opts.softtabstop
                }
                lines[row].removeSubrange(c..<cursor.col)
                touch()
                cursor.col = c
            } else if row > 0 {
                let prevLen = lines[row - 1].count
                setLine(row - 1, lines[row - 1] + lines[row])
                removeLines(row..<(row + 1))
                cursor = Pos(row - 1, prevLen)
            }
        case .delete:
            if cursor.col < lines[row].count {
                lines[row].remove(at: cursor.col); touch()
            } else if row < lastRow {
                setLine(row, lines[row] + lines[row + 1])
                removeLines((row + 1)..<(row + 2))
            }
        case .tab, .ctrl("i"):
            if opts.expandtab {
                let unit = opts.softtabstop > 0 ? opts.softtabstop : ts
                let dc = displayCol(row, cursor.col)
                let n = unit - dc % unit
                insertChars(Array(repeating: " ", count: n))
            } else {
                insertChars(["\t"])
            }
        case .ctrl("w"):
            var c = cursor.col
            let l = lines[row]
            let stop = (insertStart.row == row && insertStart.col < c) ? 0 : 0
            while c > stop && isBlank(l[c - 1]) { c -= 1 }
            if c > 0 {
                let cls = charClass(l[c - 1], false)
                while c > stop && charClass(l[c - 1], false) == cls && !isBlank(l[c - 1]) { c -= 1 }
            }
            if c < cursor.col {
                lines[row].removeSubrange(c..<cursor.col); touch()
                cursor.col = c
            } else if cursor.col == 0 && row > 0 {
                insertKey(.backspace)
                if captureInsert { insertKeys.removeLast() }
            }
        case .ctrl("u"):
            let stop = (insertStart.row == row && insertStart.col < cursor.col) ? insertStart.col : firstNonBlankStrict(row) < cursor.col ? firstNonBlankStrict(row) : 0
            if stop < cursor.col {
                lines[row].removeSubrange(stop..<cursor.col); touch()
                cursor.col = stop
            }
        case .ctrl("t"), .ctrl("d"):
            let before = lines[row].count
            shiftLines(row...row, by: key == .ctrl("t") ? 1 : -1)
            cursor.col = max(0, cursor.col + lines[row].count - before)
        case .ctrl("r"):
            insertCtrlR = true
        case .left: if cursor.col > 0 { cursor.col -= 1 }
        case .right: if cursor.col < lines[row].count { cursor.col += 1 }
        case .up: if row > 0 { cursor = Pos(row - 1, min(cursor.col, lines[row - 1].count)) }
        case .down: if row < lastRow { cursor = Pos(row + 1, min(cursor.col, lines[row + 1].count)) }
        case .home: cursor.col = 0
        case .end: cursor.col = lines[row].count
        case .char(let ch):
            if mode == .replace {
                var l = lines[row]
                if cursor.col < l.count { replaceOriginals.append(l[cursor.col]); l[cursor.col] = ch }
                else { replaceOriginals.append(nil); l.append(ch) }
                setLine(row, l)
                cursor.col += 1
            } else {
                insertChars([ch])
            }
        default: break
        }
    }

    private func insertChars(_ chars: [Character]) {
        lines[cursor.row].insert(contentsOf: chars, at: min(cursor.col, lines[cursor.row].count))
        touch()
        cursor.col += chars.count
    }

    /// Inserts arbitrary text (e.g. a system paste) at the cursor while in insert mode.
    func insertPastedText(_ s: String) {
        let t = s.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = t.components(separatedBy: "\n").map { Array($0) }
        switch mode {
        case .insert, .replace:
            cursor = insertText(parts, at: cursor)
        case .commandLine:
            cmdlineText += parts[0]
            updateIncsearch()
        default:
            break
        }
    }

    private func finishInsert() {
        if insertRepeat > 1 && !insertKeys.isEmpty {
            let keys = insertKeys
            let rep = insertRepeat
            insertRepeat = 1
            captureInsert = false
            for _ in 1..<rep {
                if insertOpenLine { openLine(below: true) }
                for k in keys { insertKey(k) }
            }
            captureInsert = true
        }
        insertRepeat = 1
        lastInserted = keysToRegisterString(insertKeys.filter { if case .char = $0 { return true }; return $0 == .enter || $0 == .tab })
        if let rc = recordingChange {
            lastChange = (rc, insertKeys)
            recordingChange = nil
        }
        marks["^"] = cursor
        marks["."] = cursor
        mode = .normal
        // Strip whitespace-only autoindent left on an otherwise empty line.
        if opts.autoindent, !lines[cursor.row].isEmpty, lines[cursor.row].allSatisfy(isBlank), insertKeys.allSatisfy({ $0 == .enter || $0 == .escape }) {
            setLine(cursor.row, [])
        }
        if cursor.col > 0 { cursor.col -= 1 }
        clampCursor()
        updateCurswant()
        replaceOriginals = []
    }

    // MARK: Command line

    private func startCmdline(_ type: Character, prefill: String = "") {
        modeBeforeCmdline = mode
        cmdlineType = type
        cmdlineText = Array(prefill)
        cmdlineOrigin = cursor
        cmdlineTopOrigin = topLine
        historyIndex = nil
        message = ""
        mode = .commandLine
    }

    private func cancelCmdline() {
        pendingSearchOperator = nil
        cursor = cmdlineOrigin
        topLine = cmdlineTopOrigin
        mode = (modeBeforeCmdline == .visual || modeBeforeCmdline == .visualLine) && cmdlineType != ":" ? modeBeforeCmdline : .normal
        cmdlineText = []
    }

    var incsearchPattern: String? {
        guard mode == .commandLine, cmdlineType != ":", opts.incsearch, !cmdlineText.isEmpty else { return nil }
        return String(cmdlineText)
    }

    private func updateIncsearch() {
        guard mode == .commandLine, cmdlineType != ":" else { return }
        cursor = cmdlineOrigin
        topLine = cmdlineTopOrigin
        guard opts.incsearch, !cmdlineText.isEmpty, let re = regex(String(cmdlineText)) else { return }
        if let p = searchFrom(cmdlineOrigin, forward: cmdlineType == "/", regex: re, quiet: true) {
            cursor = p
            scrollToCursor()
        }
    }

    private func pushHistory(_ h: inout [String], _ s: String) {
        guard !s.isEmpty else { return }
        h.removeAll { $0 == s }
        h.append(s)
        if h.count > 200 { h.removeFirst() }
    }

    private func cmdlineKey(_ key: Key) {
        if cmdlineCtrlR {
            cmdlineCtrlR = false
            if case .char(let r) = key, let c = getRegister(r) { cmdlineText += c.lines.first ?? [] }
            updateIncsearch()
            return
        }
        switch key {
        case .escape, .ctrl("["), .ctrl("c"):
            cancelCmdline()
        case .enter, .ctrl("m"), .ctrl("j"):
            let text = String(cmdlineText)
            let type = cmdlineType
            let wasVisual = modeBeforeCmdline == .visual || modeBeforeCmdline == .visualLine
            cursor = cmdlineOrigin
            topLine = cmdlineTopOrigin
            mode = wasVisual && type != ":" ? modeBeforeCmdline : .normal
            cmdlineText = []
            if type == ":" {
                pushHistory(&cmdHistory, text)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { lastExCommand = text }
                runEx(text)
            } else if let op = pendingSearchOperator {
                pendingSearchOperator = nil
                let origin = cursor
                runSearch(text, forward: type == "/")
                guard cursor != origin else { return }
                let target = cursor
                cursor = origin
                applyOp(op.name, normalizeRange(from: origin, to: target, kind: .exclusive), register: op.register, count: 1)
            } else {
                runSearch(text, forward: type == "/")
            }
        case .backspace, .ctrl("h"):
            if cmdlineText.isEmpty { cancelCmdline() } else { cmdlineText.removeLast(); updateIncsearch() }
        case .ctrl("u"):
            cmdlineText = []; updateIncsearch()
        case .ctrl("w"):
            while let l = cmdlineText.last, isBlank(l) { cmdlineText.removeLast() }
            if let l = cmdlineText.last {
                let c = charClass(l, false)
                while let l2 = cmdlineText.last, charClass(l2, false) == c, !isBlank(l2) { cmdlineText.removeLast() }
            }
            updateIncsearch()
        case .ctrl("r"):
            cmdlineCtrlR = true
        case .up, .down, .ctrl("p"), .ctrl("n"):
            let h = cmdlineType == ":" ? cmdHistory : searchHistory
            guard !h.isEmpty else { return }
            let up = key == .up || key == .ctrl("p")
            var idx = historyIndex ?? h.count
            idx = up ? max(0, idx - 1) : idx + 1
            if idx >= h.count { historyIndex = nil; cmdlineText = [] }
            else { historyIndex = idx; cmdlineText = Array(h[idx]) }
            updateIncsearch()
        case .tab:
            if cmdlineType == ":" { completeFilename() } else { cmdlineText.append("\t") }
        case .char(let c):
            cmdlineText.append(c)
            updateIncsearch()
        default: break
        }
    }

    private func completeFilename() {
        let text = String(cmdlineText)
        guard let sp = text.lastIndex(of: " ") else { return }
        let partial = String(text[text.index(after: sp)...])
        let expanded = partial.isEmpty ? FileManager.default.currentDirectoryPath + "/" : ViEngine.expandPath(partial) + (partial.hasSuffix("/") ? "/" : "")
        let dir = expanded.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = expanded.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let matches = items.filter { $0.hasPrefix(prefix) && !$0.hasPrefix(".") || (prefix.hasPrefix(".") && $0.hasPrefix(prefix)) }.sorted()
        guard !matches.isEmpty else { bell(); return }
        var common = matches[0]
        for m in matches.dropFirst() { while !m.hasPrefix(common) { common.removeLast() } }
        var completion = String(common.dropFirst(prefix.count))
        if matches.count == 1 {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(matches[0]), isDirectory: &isDir)
            if isDir.boolValue { completion += "/" }
        } else if completion.isEmpty {
            setMessage(matches.prefix(20).joined(separator: "  "))
        }
        cmdlineText += Array(completion)
    }

    // MARK: Search

    private func escapeVim(_ s: String) -> String {
        var o = ""
        for c in s { if "\\/.*$^~[]".contains(c) { o.append("\\") }; o.append(c) }
        return o
    }

    static func translateVimRegex(_ p: String) -> String {
        let chars = Array(p)
        var out = ""
        var i = 0
        if p.hasPrefix("\\v") {
            i = 2
            while i < chars.count {
                if chars[i] == "\\" && i + 1 < chars.count && (chars[i + 1] == "c" || chars[i + 1] == "C") { i += 2; continue }
                if chars[i] == "<" || chars[i] == ">" { out += "\\b"; i += 1; continue }
                out.append(chars[i]); i += 1
            }
            return out
        }
        var inBracket = false
        var inBrace = false
        while i < chars.count {
            let c = chars[i]
            if inBracket {
                if c == "\\" && i + 1 < chars.count { out.append(c); out.append(chars[i + 1]); i += 2; continue }
                if c == "[" { out += "\\[" } else { out.append(c) }
                if c == "]" { inBracket = false }
                i += 1
                continue
            }
            if c == "\\" && i + 1 < chars.count {
                let d = chars[i + 1]
                i += 2
                switch d {
                case "<", ">": out += "\\b"
                case "(", ")", "|", "+", "?": out.append(d)
                case "{": out.append("{"); inBrace = true
                case "}": out.append("}"); inBrace = false
                case "=": out += "?"
                case "c", "C": break
                default: out += "\\" + String(d)
                }
                continue
            }
            switch c {
            case "}" where inBrace: out.append("}"); inBrace = false
            case "(", ")", "|", "+", "?", "{", "}": out += "\\" + String(c)
            case "[":
                inBracket = true
                out.append(c)
                if i + 1 < chars.count && chars[i + 1] == "^" { out.append("^"); i += 1 }
                if i + 1 < chars.count && chars[i + 1] == "]" { out += "\\]"; i += 1 }
            default: out.append(c)
            }
            i += 1
        }
        return out
    }

    func regex(_ vimPattern: String, forceCase: Bool? = nil) -> NSRegularExpression? {
        var ci = opts.ignorecase
        if ci && opts.smartcase && vimPattern.contains(where: { $0.isUppercase }) { ci = false }
        if vimPattern.contains("\\c") { ci = true }
        if vimPattern.contains("\\C") { ci = false }
        if let f = forceCase { ci = f }
        let icu = ViEngine.translateVimRegex(vimPattern)
        let key = (ci ? "i:" : "c:") + icu
        if let r = regexCache[key] { return r }
        guard let r = try? NSRegularExpression(pattern: icu, options: ci ? [.caseInsensitive] : []) else { return nil }
        if regexCache.count > 64 { regexCache.removeAll() }
        regexCache[key] = r
        return r
    }

    /// Matches in a row as (start column, length) in Character units.
    func matches(row: Int, regex re: NSRegularExpression) -> [(Int, Int)] {
        let line = lines[row]
        let s = String(line)
        let ms = re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
        if ms.isEmpty { return [] }
        var offs: [Int] = []
        offs.reserveCapacity(line.count + 1)
        var u = 0
        for ch in line { offs.append(u); u += ch.utf16.count }
        offs.append(u)
        func col(_ utf16: Int) -> Int {
            var lo = 0, hi = offs.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if offs[mid] <= utf16 { lo = mid } else { hi = mid - 1 } }
            return lo
        }
        return ms.map { m in
            let a = col(m.range.location)
            let b = col(m.range.location + m.range.length)
            return (a, b - a)
        }
    }

    private func searchFrom(_ p: Pos, forward: Bool, regex re: NSRegularExpression, quiet: Bool = false) -> Pos? {
        let n = lines.count
        for k in 0...n {
            let row = forward ? (p.row + k) % n : ((p.row - k) % n + n) % n
            let wrapped = forward ? (p.row + k >= n) : (p.row - k < 0)
            if wrapped && !opts.wrapscan { return nil }
            let ms = matches(row: row, regex: re)
            if ms.isEmpty { continue }
            var hit: (Int, Int)?
            if forward {
                if k == 0 { hit = ms.first { $0.0 > p.col } }
                else if k == n { hit = ms.first { $0.0 <= p.col } }
                else { hit = ms.first }
            } else {
                if k == 0 { hit = ms.last { $0.0 < p.col } }
                else if k == n { hit = ms.last { $0.0 >= p.col } }
                else { hit = ms.last }
            }
            if let h = hit {
                if wrapped && !quiet { setError(forward ? "search hit BOTTOM, continuing at TOP" : "search hit TOP, continuing at BOTTOM") }
                return Pos(row, h.0)
            }
        }
        return nil
    }

    private func searchRepeated(_ pat: String, forward: Bool, from p: Pos, count: Int) -> Pos? {
        guard let re = regex(pat) else { setError("E383: Invalid search string: \(pat)"); return nil }
        var q = p
        for _ in 0..<count {
            guard let r = searchFrom(q, forward: forward, regex: re) else {
                setError("E486: Pattern not found: \(pat)")
                return nil
            }
            q = r
        }
        if !messageIsError { setMessage((forward == lastSearchForward ? (lastSearchForward ? "/" : "?") : (lastSearchForward ? "?" : "/")) + pat) }
        return q
    }

    private func runSearch(_ text: String, forward: Bool) {
        var pat = text
        // Strip an offset like /pat/e (offsets are not supported; ignore them).
        let delim: Character = forward ? "/" : "?"
        var esc = false
        for (i, c) in pat.enumerated() {
            if esc { esc = false; continue }
            if c == "\\" { esc = true; continue }
            if c == delim { pat = String(pat.prefix(i)); break }
        }
        if pat.isEmpty {
            guard let ls = lastSearch else { setError("E35: No previous regular expression"); return }
            pat = ls
        }
        lastSearch = pat
        lastSearchForward = forward
        hlsearchActive = true
        pushHistory(&searchHistory, text)
        guard let q = searchRepeated(pat, forward: forward, from: cursor, count: 1) else { return }
        if !messageIsError { setMessage(String(delim) + pat) }
        setJumpMark()
        cursor = q
        updateCurswant()
    }

    /// Patterns that should be highlighted right now (for the view).
    func highlightRegex() -> NSRegularExpression? {
        if let p = incsearchPattern { return regex(p) }
        guard opts.hlsearch, hlsearchActive, let p = lastSearch, !p.isEmpty else { return nil }
        return regex(p)
    }

    // MARK: Ex commands

    func runEx(_ input: String) {
        do { try exCommand(input) } catch let e as ExError { setError(e.msg) } catch { setError("\(error)") }
    }

    private func parseAddress(_ s: [Character], _ i: inout Int) throws -> Int? {
        while i < s.count && s[i] == " " { i += 1 }
        var base: Int?
        if i < s.count {
            let c = s[i]
            if c.isASCII && c.isNumber {
                var v = 0
                while i < s.count, s[i].isASCII, let d = s[i].wholeNumberValue { v = v * 10 + d; i += 1 }
                base = v - 1
            } else if c == "." {
                base = cursor.row; i += 1
            } else if c == "$" {
                base = lastRow; i += 1
            } else if c == "'" {
                guard i + 1 < s.count else { throw ExError("E20: Mark not set") }
                let m = s[i + 1]
                i += 2
                guard let p = markPos(m) else { throw ExError("E20: Mark not set") }
                base = p.row
            } else if c == "/" || c == "?" {
                var j = i + 1
                var pat = ""
                while j < s.count && s[j] != c {
                    if s[j] == "\\" && j + 1 < s.count { pat.append(s[j]); j += 1 }
                    pat.append(s[j]); j += 1
                }
                i = min(s.count, j + 1)
                if pat.isEmpty { pat = lastSearch ?? "" }
                guard let re = regex(pat) else { throw ExError("E383: Invalid search string: \(pat)") }
                let start = c == "/" ? Pos(cursor.row, lines[cursor.row].count) : Pos(cursor.row, 0)
                guard let p = searchFrom(start, forward: c == "/", regex: re, quiet: true) else { throw ExError("E486: Pattern not found: \(pat)") }
                lastSearch = pat
                base = p.row
            }
        }
        while i < s.count && (s[i] == "+" || s[i] == "-") {
            let sign = s[i] == "+" ? 1 : -1
            i += 1
            var v = 0
            var any = false
            while i < s.count, s[i].isASCII, let d = s[i].wholeNumberValue { v = v * 10 + d; i += 1; any = true }
            base = (base ?? cursor.row) + sign * (any ? v : 1)
        }
        return base
    }

    private static let exCommands: [(String, String)] = [
        ("append", "a"), ("change", "c"), ("copy", "co"), ("cd", "cd"), ("delete", "d"), ("display", "di"),
        ("edit", "e"), ("enew", "ene"), ("exit", "exi"), ("file", "f"), ("global", "g"), ("help", "h"),
        ("join", "j"), ("k", "k"), ("mark", "ma"), ("marks", "marks"), ("move", "m"), ("nohlsearch", "noh"),
        ("normal", "norm"), ("print", "p"), ("put", "pu"), ("pwd", "pw"), ("quit", "q"), ("qall", "qa"),
        ("quitall", "quita"), ("read", "r"), ("redo", "red"), ("registers", "reg"), ("saveas", "sav"),
        ("set", "se"), ("sort", "sor"), ("substitute", "s"), ("t", "t"), ("undo", "u"), ("vglobal", "v"),
        ("version", "ve"), ("write", "w"), ("wall", "wa"), ("wq", "wq"), ("wqall", "wqa"), ("xit", "x"),
        ("xall", "xa"), ("yank", "y"),
    ]

    private func resolveExName(_ name: String) -> String? {
        if ["&", "&&", "<", ">", "=", "!", "~"].contains(where: { name == $0 }) || name.allSatisfy({ $0 == "<" }) || name.allSatisfy({ $0 == ">" }) { return name }
        for (full, abbr) in ViEngine.exCommands where name.count >= abbr.count && full.hasPrefix(name) { return full }
        return nil
    }

    private func exCommand(_ input: String) throws {
        let s = Array(input)
        var i = 0
        while i < s.count && (s[i] == ":" || s[i] == " " || s[i] == "\t") { i += 1 }
        if i >= s.count { return }
        if s[i] == "\"" { return }
        var addrs: [Int] = []
        var hasRange = false
        if s[i] == "%" {
            addrs = [0, lastRow]; i += 1; hasRange = true
        } else {
            if let a = try parseAddress(s, &i) { addrs.append(a); hasRange = true }
            while i < s.count && (s[i] == "," || s[i] == ";") {
                if addrs.isEmpty { addrs.append(cursor.row) }
                if s[i] == ";", let a = addrs.last { cursor.row = max(0, min(lastRow, a)) }
                i += 1
                addrs.append(try parseAddress(s, &i) ?? cursor.row)
                hasRange = true
            }
        }
        while i < s.count && s[i] == " " { i += 1 }
        let r1 = addrs.count >= 2 ? addrs[addrs.count - 2] : addrs.first
        let r2 = addrs.last

        if i >= s.count {
            guard let target = r2 else { return }
            let row = max(0, min(lastRow, target))
            setJumpMark()
            cursor = Pos(row, firstNonBlank(row))
            updateCurswant()
            return
        }

        var name = ""
        if s[i].isLetter {
            while i < s.count && s[i].isLetter && s[i].isASCII { name.append(s[i]); i += 1 }
            // ":s" followed by letters is not valid; but allow :substitute flags like ":sg"? (not supported)
        } else {
            name = String(s[i]); i += 1
            if name == "<" || name == ">" || name == "&" { while i < s.count && s[i] == name.first! { name.append(s[i]); i += 1 } }
        }
        var bang = false
        if i < s.count && s[i] == "!" && name != "!" { bang = true; i += 1 }
        let rawArg = i < s.count ? String(s[i...]) : ""
        let arg = rawArg.trimmingCharacters(in: .whitespaces)
        guard let cmd = resolveExName(name) else { throw ExError("E492: Not an editor command: \(input.trimmingCharacters(in: .whitespaces))") }

        func range(_ defLo: Int? = nil, _ defHi: Int? = nil) throws -> (Int, Int) {
            var lo = r1 ?? defLo ?? cursor.row
            var hi = r2 ?? defHi ?? cursor.row
            if lo > hi { swap(&lo, &hi) }
            guard lo >= 0, hi <= lastRow else { throw ExError("E16: Invalid range") }
            return (lo, hi)
        }
        func regArg() -> Character? {
            guard let c = arg.first, ViEngine.isRegisterName(c), !c.isNumber || arg.count == 1 else { return nil }
            return c
        }

        switch cmd {
        case "write", "wall":
            if arg.hasPrefix("!") { throw ExError("E: Shell commands are not available") }
            let target = arg.isEmpty ? filePath : ViEngine.expandPath(arg)
            guard let t = target else {
                if let cb = onSaveAs { cb(); return }
                throw ExError("E32: No file name")
            }
            if !arg.isEmpty && t != filePath && FileManager.default.fileExists(atPath: t) && !bang {
                throw ExError("E13: File exists (add ! to override)")
            }
            try write(to: t)
        case "quit", "qall", "quitall":
            if modified && !bang { throw ExError("E37: No write since last change (add ! to override)") }
            onQuit?()
        case "wq", "wqall":
            let target = arg.isEmpty ? filePath : ViEngine.expandPath(arg)
            guard let t = target else { throw ExError("E32: No file name") }
            try write(to: t)
            onQuit?()
        case "xit", "exit", "xall":
            if modified {
                let target = arg.isEmpty ? filePath : ViEngine.expandPath(arg)
                guard let t = target else { throw ExError("E32: No file name") }
                try write(to: t)
            }
            onQuit?()
        case "edit":
            if modified && !bang { throw ExError("E37: No write since last change (add ! to override)") }
            if arg.isEmpty {
                guard let p = filePath else { throw ExError("E32: No file name") }
                openFile(p)
            } else {
                openFile(arg)
            }
        case "enew":
            if modified && !bang { throw ExError("E37: No write since last change (add ! to override)") }
            filePath = nil
            load(text: "")
        case "saveas":
            guard !arg.isEmpty else { throw ExError("E471: Argument required") }
            let t = ViEngine.expandPath(arg)
            if FileManager.default.fileExists(atPath: t) && !bang { throw ExError("E13: File exists (add ! to override)") }
            let old = filePath
            filePath = t
            do { try write(to: t) } catch { filePath = old; throw error }
        case "file":
            if !arg.isEmpty { filePath = ViEngine.expandPath(arg); savedStateId = -1 }
            showFileInfo()
        case "substitute", "&", "&&", "~":
            let (lo, hi) = try range()
            var a = arg
            if cmd == "&&" { a = "&" }
            try substitute(lo, hi, cmd == "substitute" ? a : (a.isEmpty ? "" : a), repeatOnly: cmd != "substitute")
        case "set":
            try setOptions(arg)
        case "nohlsearch":
            hlsearchActive = false
        case "delete":
            let (lo, hi) = try range()
            let content = RegisterContent(lines: Array(lines[lo...hi]), linewise: true)
            storeRegister(regArg(), content, isDelete: true)
            removeLines(lo..<(hi + 1))
            let row = min(lo, lastRow)
            cursor = Pos(row, firstNonBlank(row))
            reportLines(hi - lo + 1, "fewer lines")
        case "yank":
            let (lo, hi) = try range()
            storeRegister(regArg(), RegisterContent(lines: Array(lines[lo...hi]), linewise: true), isDelete: false)
            reportLines(hi - lo + 1, "lines yanked")
        case "put":
            let row = r2 ?? cursor.row
            guard row >= -1, row <= lastRow else { throw ExError("E16: Invalid range") }
            guard var content = getRegister(regArg()) else { throw ExError("E353: Nothing in register") }
            content.linewise = true
            let at = bang ? max(0, row) : row + 1
            insertLines(content.lines, at: at)
            let last = at + content.lines.count - 1
            cursor = Pos(last, firstNonBlank(last))
        case "join":
            var (lo, hi) = try range()
            if lo == hi { hi = min(lastRow, lo + 1) }
            if let n = Int(arg) { hi = min(lastRow, hi + n - 1) }
            cursor.row = lo
            joinLines(lo, count: hi - lo + 1, spaces: !bang)
        case "global", "vglobal":
            let (lo, hi) = try range(0, lastRow)
            try global(arg, lo, hi, invert: cmd == "vglobal" || bang)
        case "read":
            guard !arg.isEmpty else { throw ExError("E32: No file name") }
            if arg.hasPrefix("!") { throw ExError("E: Shell commands are not available") }
            let p = ViEngine.expandPath(arg)
            guard let data = FileManager.default.contents(atPath: p) else { throw ExError("E484: Can't open file \(arg)") }
            var parts = (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            if parts.count > 1, parts.last == "" { parts.removeLast() }
            let row = r2 ?? cursor.row
            insertLines(parts.map { Array($0) }, at: row + 1)
            cursor = Pos(row + 1, firstNonBlank(row + 1))
            setMessage("\"\(arg)\" \(parts.count)L, \(data.count)B")
        case "sort":
            let (lo, hi) = try range(0, lastRow)
            let ic = arg.contains("i"), num = arg.contains("n"), uniq = arg.contains("u")
            var block = Array(lines[lo...hi]).map { String($0) }
            if num {
                func key(_ s: String) -> Int {
                    guard let r = s.range(of: "-?[0-9]+", options: .regularExpression) else { return Int.min }
                    return Int(s[r]) ?? Int.min
                }
                block.sort { key($0) < key($1) }
            } else if ic {
                block.sort { $0.lowercased() < $1.lowercased() }
            } else {
                block.sort()
            }
            if bang { block.reverse() }
            if uniq {
                var out: [String] = []
                for l in block where out.last.map({ ic ? $0.lowercased() != l.lowercased() : $0 != l }) ?? true { out.append(l) }
                block = out
            }
            removeLines(lo..<(hi + 1))
            if lines.count == 1 && lines[0].isEmpty && lo == 0 {
                lines = block.map { Array($0) }
                touch()
            } else {
                insertLines(block.map { Array($0) }, at: lo)
            }
            cursor = Pos(lo, 0)
        case "registers", "display":
            var out = ["Type Name Content"]
            var names: [Character] = ["\"", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "-"]
            names += registers.keys.filter { $0.isLetter }.sorted()
            for n in names {
                guard let c = registers[n] else { continue }
                if !arg.isEmpty && !arg.contains(n) { continue }
                let t = visibleControlChars(c.lines.map { String($0) }.joined(separator: "^J"))
                out.append("  \(c.linewise ? "l" : "c")  \"\(n)   \(t.prefix(200))")
            }
            if let ls = lastSearch { out.append("  c  \"/   \(ls)") }
            if let le = lastExCommand { out.append("  c  \":   \(le)") }
            if filePath != nil { out.append("  c  \"%   \(displayName)") }
            pager = out
        case "marks":
            var out = ["mark line  col text"]
            for (k, p) in marks.sorted(by: { $0.key < $1.key }) where p.row < lines.count {
                out.append(" \(k)  \(String(format: "%6d %4d", p.row + 1, p.col)) \(String(lines[p.row]).prefix(80))")
            }
            pager = out
        case "undo": undo(1)
        case "redo": redo(1)
        case "help": pager = ViEngine.helpText
        case "version": setMessage("ViKit 1.0 — a vi for macOS built with UIKit (Mac Catalyst)")
        case "normal":
            let (lo, hi) = try range()
            let keys = parseKeyNotation(rawArg.hasPrefix(" ") ? String(rawArg.dropFirst()) : rawArg)
            try forEachRow(Array(lo...hi)) { r in
                self.cursor = Pos(r, 0)
                self.mode = .normal
                self.pendingKeys = []
                for k in keys { self.feed(k) }
                if self.mode == .insert || self.mode == .replace { self.finishInsert() }
                if self.mode == .commandLine { self.cancelCmdline() }
                if self.isVisual { self.exitVisual() }
                self.pendingKeys = []
            }
        case "move":
            let (lo, hi) = try range()
            var j = 0
            let a = Array(arg)
            guard let t = try parseAddress(a, &j) else { throw ExError("E14: Invalid address") }
            guard t >= -1, t <= lastRow else { throw ExError("E16: Invalid range") }
            if t >= lo && t < hi { throw ExError("E134: Cannot move a range of lines into itself") }
            if t == hi || t == lo - 1 { return }
            let block = Array(lines[lo...hi])
            removeLines(lo..<(hi + 1))
            let dest = t > hi ? t - block.count + 1 : t + 1
            insertLines(block, at: dest)
            cursor = Pos(dest + block.count - 1, firstNonBlank(dest + block.count - 1))
        case "copy", "t":
            let (lo, hi) = try range()
            var j = 0
            let a = Array(arg)
            guard let t = try parseAddress(a, &j) else { throw ExError("E14: Invalid address") }
            guard t >= -1, t <= lastRow else { throw ExError("E16: Invalid range") }
            let block = Array(lines[lo...hi])
            insertLines(block, at: t + 1)
            cursor = Pos(t + block.count, firstNonBlank(t + block.count))
        case "k", "mark":
            guard let c = arg.first, c.isLetter else { throw ExError("E471: Argument required") }
            marks[c] = Pos(r2 ?? cursor.row, 0)
        case "print":
            let (lo, hi) = try range()
            if hi > lo { pager = (lo...hi).map { String(lines[$0]) } } else { setMessage(String(lines[lo])) }
        case "=":
            setMessage("\((r2 ?? lastRow) + 1)")
        case "pwd":
            setMessage(FileManager.default.currentDirectoryPath)
        case "cd":
            let p = arg.isEmpty ? (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) : ViEngine.expandPath(arg)
            guard FileManager.default.changeCurrentDirectoryPath(p) else { throw ExError("E344: Can't find directory \"\(arg)\"") }
            setMessage(p)
        case "!":
            throw ExError("E: Shell commands are not available in ViKit")
        default:
            if cmd.allSatisfy({ $0 == ">" }) || cmd.allSatisfy({ $0 == "<" }) {
                var (lo, hi) = try range()
                if let n = Int(arg) { lo = hi; hi = min(lastRow, lo + n - 1) }
                shiftLines(lo...hi, by: (cmd.first == ">" ? 1 : -1) * cmd.count)
                cursor = Pos(hi, firstNonBlank(hi))
            } else {
                throw ExError("E492: Not an editor command: \(input)")
            }
        }
        _ = hasRange
    }

    /// Run `body` for each original row, remapping rows as earlier iterations insert/delete lines.
    private func forEachRow(_ rows: [Int], _ body: (Int) throws -> Void) throws {
        let outer = lineEditLog
        lineEditLog = []
        defer {
            if var o = outer { o += lineEditLog ?? []; lineEditLog = o } else { lineEditLog = nil }
        }
        for orig in rows {
            var x = orig
            var gone = false
            for e in lineEditLog! {
                if e.delta > 0 { if x >= e.at { x += e.delta } }
                else if x >= e.removedEnd { x += e.delta }
                else if x >= e.at { gone = true; break }
            }
            if gone || x > lastRow { continue }
            try body(x)
        }
    }

    private func splitDelimited(_ s: String, _ delim: Character, maxParts: Int) -> [String] {
        var parts: [String] = []
        var cur = ""
        var chars = Array(s)
        var i = 0
        chars = Array(chars)
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                if chars[i + 1] == delim && delim != "/" { cur.append(delim) } else { cur.append(c); cur.append(chars[i + 1]) }
                i += 2
                continue
            }
            if c == delim && parts.count < maxParts - 1 {
                parts.append(cur); cur = ""; i += 1
                continue
            }
            cur.append(c)
            i += 1
        }
        parts.append(cur)
        return parts
    }

    static func translateReplacement(_ r: String) -> String {
        var out = ""
        let c = Array(r)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\" && i + 1 < c.count {
                let d = c[i + 1]
                i += 2
                if d.isASCII && d.isNumber { out += "$" + String(d) }
                else if d == "n" || d == "r" { out += "\n" }
                else if d == "t" { out += "\t" }
                else if d == "\\" { out += "\\\\" }
                else if d == "$" { out += "\\$" }
                else { out.append(d) }
                continue
            }
            if ch == "&" { out += "$0" } else if ch == "$" { out += "\\$" } else { out.append(ch) }
            i += 1
        }
        return out
    }

    private var substituteSilent = false

    private func substitute(_ lo: Int, _ hi: Int, _ arg: String, repeatOnly: Bool) throws {
        var pattern: String, replacement: String, flags: String
        if repeatOnly || arg.isEmpty || arg.first!.isLetter || arg.first == "&" {
            guard let last = lastSubstitute else { throw ExError("E35: No previous regular expression") }
            pattern = last.pattern; replacement = last.replacement
            flags = arg.hasPrefix("&") ? last.flags + arg.dropFirst() : arg
        } else {
            let delim = arg.first!
            guard !delim.isNumber, delim != "\\", delim != "\"", delim != "|", delim != " " else { throw ExError("E146: Regular expressions can't be delimited by letters") }
            let parts = splitDelimited(String(arg.dropFirst()), delim, maxParts: 3)
            pattern = parts[0]
            replacement = parts.count > 1 ? parts[1] : ""
            flags = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            if pattern.isEmpty {
                guard let ls = lastSearch else { throw ExError("E35: No previous regular expression") }
                pattern = ls
            }
            lastSubstitute = (pattern, replacement, flags)
        }
        lastSearch = pattern
        hlsearchActive = true
        let global = flags.contains("g")
        let countOnly = flags.contains("n")
        var force: Bool?
        if flags.contains("i") { force = true }
        if flags.contains("I") { force = false }
        guard let re = regex(pattern, forceCase: force) else { throw ExError("E383: Invalid search string: \(pattern)") }
        let template = ViEngine.translateReplacement(replacement)
        var row = lo, end = hi
        var count = 0, lineCount = 0, lastChanged = -1
        while row <= end && row <= lastRow {
            let line = String(lines[row])
            let ns = line as NSString
            let ms = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if ms.isEmpty { row += 1; continue }
            let used = global ? ms : [ms[0]]
            count += used.count
            lineCount += 1
            if countOnly { row += 1; continue }
            var result = ""
            var lastEnd = 0
            for m in used {
                result += ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
                result += re.replacementString(for: m, in: line, offset: 0, template: template)
                lastEnd = m.range.location + m.range.length
            }
            result += ns.substring(from: lastEnd)
            let parts = result.components(separatedBy: "\n").map { Array($0) }
            setLine(row, parts[0])
            if parts.count > 1 {
                insertLines(Array(parts[1...]), at: row + 1)
                row += parts.count - 1
                end += parts.count - 1
            }
            lastChanged = row
            row += 1
        }
        if count == 0 {
            if flags.contains("e") || substituteSilent { return }
            throw ExError("E486: Pattern not found: \(pattern)")
        }
        if countOnly { setMessage("\(count) match\(count == 1 ? "" : "es") on \(lineCount) line\(lineCount == 1 ? "" : "s")"); return }
        cursor = Pos(lastChanged, firstNonBlank(lastChanged))
        updateCurswant()
        if lineCount > 2 || count > 2 && !substituteSilent {
            setMessage("\(count) substitution\(count == 1 ? "" : "s") on \(lineCount) line\(lineCount == 1 ? "" : "s")")
        }
    }

    private func global(_ arg: String, _ lo: Int, _ hi: Int, invert: Bool) throws {
        guard let delim = arg.first else { throw ExError("E35: No previous regular expression") }
        let parts = splitDelimited(String(arg.dropFirst()), delim, maxParts: 2)
        var pattern = parts[0]
        if pattern.isEmpty {
            guard let ls = lastSearch else { throw ExError("E35: No previous regular expression") }
            pattern = ls
        }
        let sub = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        guard let re = regex(pattern) else { throw ExError("E383: Invalid search string: \(pattern)") }
        let rows = (lo...hi).filter { matches(row: $0, regex: re).isEmpty == invert }
        lastSearch = pattern
        hlsearchActive = true
        if rows.isEmpty { setMessage("Pattern not found: \(pattern)"); return }
        if sub.isEmpty || sub == "p" || sub == "print" || sub == "#" || sub == "nu" {
            pager = rows.map { sub.isEmpty || sub.hasPrefix("p") ? String(lines[$0]) : String(format: "%6d ", $0 + 1) + String(lines[$0]) }
            return
        }
        let wasSilent = substituteSilent
        substituteSilent = true
        defer { substituteSilent = wasSilent }
        var lastErr: ExError?
        try forEachRow(rows) { r in
            self.cursor = Pos(r, 0)
            do { try self.exCommand(sub) } catch let e as ExError { lastErr = e }
        }
        if let e = lastErr, !e.msg.hasPrefix("E486") { throw e }
        let row = min(cursor.row, lastRow)
        cursor = Pos(row, firstNonBlank(row))
    }

    func setOptions(_ arg: String) throws {
        if arg.isEmpty || arg == "all" {
            var parts: [String] = []
            let d = Options()
            for (n, _, kp) in Options.bools where opts[keyPath: kp] != d[keyPath: kp] { parts.append(opts[keyPath: kp] ? n : "no" + n) }
            for (n, _, kp) in Options.ints where opts[keyPath: kp] != d[keyPath: kp] { parts.append("\(n)=\(opts[keyPath: kp])") }
            if !opts.clipboard.isEmpty { parts.append("clipboard=\(opts.clipboard)") }
            setMessage(parts.isEmpty ? "--- Options --- (all defaults)" : parts.joined(separator: "  "))
            return
        }
        var shown: [String] = []
        for tokS in arg.split(separator: " ") {
            var tok = String(tokS)
            func boolKP(_ n: String) -> WritableKeyPath<Options, Bool>? { Options.bools.first { $0.0 == n || $0.1 == n }?.2 }
            func intKP(_ n: String) -> WritableKeyPath<Options, Int>? { Options.ints.first { $0.0 == n || $0.1 == n }?.2 }
            if let eq = tok.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                let n = String(tok[..<eq]).replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: "")
                let v = String(tok[tok.index(after: eq)...])
                if let kp = intKP(n) {
                    guard let iv = Int(v), iv >= 0 else { throw ExError("E521: Number required after =: \(tok)") }
                    opts[keyPath: kp] = (n == "tabstop" || n == "ts") ? max(1, iv) : iv
                } else if n == "clipboard" || n == "cb" {
                    opts.clipboard = v
                } else {
                    throw ExError("E518: Unknown option: \(tok)")
                }
                continue
            }
            var query = false, toggle = false
            if tok.hasSuffix("?") { query = true; tok.removeLast() }
            if tok.hasSuffix("!") { toggle = true; tok.removeLast() }
            if let kp = boolKP(tok) {
                if query { shown.append((opts[keyPath: kp] ? "  " : "no") + tok) }
                else if toggle { opts[keyPath: kp].toggle() }
                else { opts[keyPath: kp] = true }
            } else if tok.hasPrefix("no"), let kp = boolKP(String(tok.dropFirst(2))) {
                opts[keyPath: kp] = false
            } else if tok.hasPrefix("inv"), let kp = boolKP(String(tok.dropFirst(3))) {
                opts[keyPath: kp].toggle()
            } else if let kp = intKP(tok) {
                shown.append("  \(tok)=\(opts[keyPath: kp])")
            } else if tok == "clipboard" || tok == "cb" {
                shown.append("  clipboard=\(opts.clipboard)")
            } else if ["wrap", "nowrap", "ruler", "noruler", "showmode", "noshowmode", "showcmd", "noshowcmd", "nocompatible", "compatible"].contains(tok) {
                continue
            } else {
                throw ExError("E518: Unknown option: \(tok)")
            }
        }
        if opts.hlsearch { hlsearchActive = true }
        if !shown.isEmpty { setMessage(shown.joined(separator: " ")) }
    }

    // MARK: Status helpers

    var modeLabel: String {
        switch mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .replace: return "REPLACE"
        case .visual: return "VISUAL"
        case .visualLine: return "V-LINE"
        case .commandLine: return modeBeforeCmdline == .visual || modeBeforeCmdline == .visualLine ? "VISUAL" : "COMMAND"
        }
    }

    var rulerText: String {
        let col = cursor.col + 1
        let vcol = displayCol(cursor.row, cursor.col) + 1
        let colStr = lines[cursor.row].isEmpty ? "0-1" : (col == vcol ? "\(col)" : "\(col)-\(vcol)")
        let pos: String
        if lines.count <= visibleRows { pos = "All" }
        else if topLine == 0 { pos = "Top" }
        else if topLine + visibleRows >= lines.count { pos = "Bot" }
        else { pos = "\(topLine * 100 / max(1, lines.count - visibleRows))%" }
        return "\(cursor.row + 1):\(colStr)  \(pos)"
    }

    static let helpText: [String] = [
        "ViKit — vi for macOS (UIKit / Mac Catalyst)",
        "",
        "MOVING   h j k l  w b e W B E ge  0 ^ $ g_  gg G {n}G  f F t T ; ,  % H M L { }",
        "         ^d ^u ^f ^b ^e ^y  zz zt zb   mx 'x `x ''   / ? n N * #",
        "EDITING  i a I A o O  x X r R s S C D  J gJ  ~ ^a ^x  p P  u ^r U  .",
        "OPS      d c y > < g~ gu gU + motion or text object (iw aw i\" a( i{ ip ...)",
        "         doubled = linewise (dd cc yy >> gUU) ; counts everywhere (3dw, 2d3w)",
        "VISUAL   v V  o  then d y c r J > < ~ u U p ;  gv reselects ;  :  for '<,'>",
        "MACROS   qa ... q to record into a, @a to play, @@ to repeat ;  \"ayy \"ap registers",
        "         \"+ / \"* is the macOS clipboard   (or  :set clipboard=unnamed)",
        "",
        "EX       :w [file] :w! :q :q! :wq :x ZZ ZQ :e file :e! :enew :sav file :r file",
        "         :[range]s/pat/rep/[gine]  :g/pat/cmd  :v/pat/cmd  :d :y :pu :j :m :t :> :<",
        "         :sort [n i u]  :norm keys  :{n}  :noh  :reg  :marks  :cd :pwd  :help",
        "         ranges: % . $ 'a '<,'> /pat/ +n -n",
        "SET      nu rnu ic scs hls is et ai ws cul list  ts= sw= sts= so= clipboard=",
        "         Options are read from ~/.exrc, ~/.vimrc and ~/.vikitrc (set lines only).",
        "",
        "MAC      ⌘O open  ⌘S save  ⌘N new window  ⌘C/⌘X/⌘V clipboard  ⌘+ ⌘- font size",
    ]
}
