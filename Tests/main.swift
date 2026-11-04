// Headless tests for ViEngine. Build & run with ./test.sh
import Foundation

var failures = 0
var passes = 0

/// `start` uses "|" to mark the cursor (placed on the char after it). Expected text likewise marks cursor.
func t(_ name: String, _ start: String, _ keys: String, _ expected: String, setup: ((ViEngine) -> Void)? = nil, file: Int = #line) {
    let e = ViEngine()
    e.visibleRows = 20
    e.opts.scrolloff = 0
    var text = start
    var cur = Pos(0, 0)
    if let r = text.firstIndex(of: "|") {
        let before = text[..<r]
        let row = before.filter { $0 == "\n" }.count
        let col = before.split(separator: "\n", omittingEmptySubsequences: false).last.map { $0.count } ?? 0
        cur = Pos(row, col)
        text.remove(at: r)
    }
    e.load(text: text)
    e.cursor = cur
    e.curswant = e.displayCol(cur.row, cur.col)
    setup?(e)
    e.feed(parseKeyNotation(keys))
    var got = e.lines.map { String($0) }
    let expectsCursor = expected.contains("|")
    if expectsCursor {
        var l = Array(got[e.cursor.row])
        l.insert("|", at: min(e.cursor.col, l.count))
        got[e.cursor.row] = String(l)
    }
    let gotS = got.joined(separator: "\n")
    let want = expected.hasSuffix("\n") ? String(expected.dropLast()) : expected
    if gotS == want {
        passes += 1
    } else {
        failures += 1
        print("FAIL [\(name)] line \(file)\n  keys: \(keys)\n  want: \(want.debugDescription)\n  got:  \(gotS.debugDescription)  mode=\(e.mode) msg=\(e.message)")
    }
}

// Motions
t("w", "|foo bar baz", "w", "foo |bar baz")
t("2w", "|foo bar baz", "2w", "foo bar |baz")
t("w punct", "|foo.bar baz", "w", "foo|.bar baz")
t("W", "|foo.bar baz", "W", "foo.bar |baz")
t("b", "foo bar |baz", "b", "foo |bar baz")
t("e", "|foo bar", "e", "fo|o bar")
t("e twice", "|foo bar", "ee", "foo ba|r")
t("ge", "foo |bar", "ge", "fo|o bar")
t("w across lines", "foo |bar\nbaz", "w", "foo bar\n|baz")
t("w empty line", "|foo\n\nbar", "w", "foo\n|\nbar")
t("$", "|hello", "$", "hell|o")
t("0", "  hel|lo", "0", "|  hello")
t("^", "  hel|lo", "^", "  |hello")
t("gg", "a\nb\n|c", "gg", "|a\nb\nc")
t("G", "|a\nb\nc", "G", "a\nb\n|c")
t("3G", "|a\nb\nc\nd", "3G", "a\nb\n|c\nd")
t("f", "|abcabc", "fc", "ab|cabc")
t("2f", "|abcabc", "2fc", "abcab|c")
t("t", "|abcabc", "tc", "a|bcabc")
t(";", "|a,b,c", "f,;", "a,b|,c")
t(",", "|a,b,c", "f,;,", "a|,b,c")
t("F", "abc|abc", "Fa", "|abcabc")
t("%", "|(a (b) c)", "%", "(a (b) c|)")
t("% back", "(a (b) c|)", "%", "|(a (b) c)")
t("% multi", "|{\n  x\n}", "%", "{\n  x\n|}")
t("}", "|a\nb\n\nc", "}", "a\nb\n|\nc")
t("{", "a\n\nb\n|c", "{", "a\n|\nb\nc")
t("j curswant", "abc|d\nx\nabcdef", "jj", "abcd\nx\nabc|def")
t("$ then j", "ab|c\nabcdef", "$j", "abc\nabcde|f")
t("count l", "|abcdef", "3l", "abc|def")
t("l at end", "ab|c", "l", "ab|c")
t("H/L", "a\nb\n|c", "H", "|a\nb\nc")
t("mark", "|a\nb\nc", "majj'a", "|a\nb\nc")
t("backtick mark", "a|bc\nd", "mxj`x", "a|bc\nd")
t("''", "|a\nb\nc", "G''", "|a\nb\nc")

// Deletion / change
t("x", "|abc", "x", "|bc")
t("3x", "|abcd", "3x", "|d")
t("x end", "ab|c", "x", "a|b")
t("X", "ab|c", "X", "a|c")
t("dw", "|foo bar", "dw", "|bar")
t("dw last word", "foo |bar\nbaz", "dw", "foo| \nbaz")
t("d2w", "|a b c", "d2w", "|c")
t("2dw", "|a b c", "2dw", "|c")
t("de", "|foo bar", "de", "| bar")
t("db", "foo |bar", "db", "|bar")
t("dd", "a\n|b\nc", "dd", "a\n|c")
t("dd last", "a\nb\n|c", "dd", "a\n|b")
t("dd only", "|a", "dd", "|")
t("3dd", "|a\nb\nc\nd", "3dd", "|d")
t("dj", "|a\nb\nc", "dj", "|c")
t("dk", "a\n|b\nc", "dk", "|c")
t("dG", "a\n|b\nc", "dG", "|a")
t("dgg", "a\n|b\nc", "dgg", "|c")
t("d$", "ab|cd", "d$", "a|b")
t("D", "ab|cd", "D", "a|b")
t("d0", "ab|cd", "d0", "|cd")
t("dt", "|a,b,c", "dt,", "|,b,c")
t("df", "|a,b,c", "df,", "|b,c")
t("d}", "|a\nb\n\nc", "d}", "|\nc")
t("d} mid", "x|a\nb\n\nc", "d}", "|x\n\nc")
t("diw", "foo b|ar baz", "diw", "foo | baz")
t("daw", "foo b|ar baz", "daw", "foo |baz")
t("daw end", "foo b|ar", "daw", "fo|o")
t("di(", "f(a, |b)", "di(", "f(|)")
t("da(", "f(a, |b) x", "da(", "f| x")
t("dib", "f(a, |b)", "dib", "f(|)")
t("di\"", "x = \"he|llo\"", "di\"", "x = \"|\"")
t("da\"", "x = \"he|llo\" y", "da\"", "x = |y")
t("ci\" before", "|x = \"hello\"", "ci\"bye<Esc>", "x = \"by|e\"")
t("di{ linewise", "if {\n  a\n  |b\n}", "di{", "if {\n|}")
t("dip", "a\n|b\n\nc", "dip", "|\nc")
t("dap", "a\n|b\n\nc", "dap", "|c")
t("cw", "|foo bar", "cwxy<Esc>", "x|y bar")
t("cw single", "|a bar", "cwxy<Esc>", "x|y bar")
t("cw end", "fo|o bar", "cwX<Esc>", "fo|X bar")
t("c2w", "|a b c", "c2wX<Esc>", "|X c")
t("cc", "  |foo\nbar", "ccx<Esc>", "  |x\nbar")
t("S", "  |foo", "Sx<Esc>", "  |x")
t("C", "ab|cd", "Cx<Esc>", "ab|x")
t("s", "|abc", "sX<Esc>", "|Xbc")
t("3s", "|abcd", "3sX<Esc>", "|Xd")
t("r", "|abc", "rx", "|xbc")
t("3r", "|abcd", "3rx", "xx|xd")
t("r too many", "|ab", "3rx", "|ab")
t("r enter", "ab|cd", "r<CR>", "ab\n|d")
t("~", "|abc", "~~", "AB|c")
t("g~w", "|abc def", "g~w", "|ABC def")
t("gUiw", "a|bc", "gUiw", "|ABC")
t("guu", "A|BC", "guu", "|abc")
t("gUU", "a|bc", "gUU", "|ABC")
t("J", "|a\n  b", "J", "a| b")
t("3J", "|a\nb\nc", "3J", "a b| c")
t("gJ", "|a\n  b", "gJ", "|a  b")
t("J paren", "|f(\n)", "J", "f(|)")
t(">>", "|a", ">>", "\t|a")
t(">> sw", "|a", ">>", "  |a", setup: { $0.opts.shiftwidth = 2; $0.opts.expandtab = true })
t("<<", "\t|a", "<<", "|a")
t("3>>", "|a\nb\nc\nd", "3>>", "\t|a\n\tb\n\tc\nd")
t(">j", "|a\nb\nc", ">j", "\t|a\n\tb\nc")
t("^a", "x |9 y", "<C-a>", "x 1|0 y")
t("5^a", "|x 10", "5<C-a>", "x 1|5")
t("^x neg", "|x 0", "<C-x>", "x -|1")

// Insert
t("i", "a|c", "ib<Esc>", "a|bc")
t("a", "|ac", "ab<Esc>", "a|bc")
t("A", "|ab", "Acd<Esc>", "abc|d")
t("I", "  a|b", "Ix<Esc>", "  |xab")
t("o", "|a\nc", "ob<Esc>", "a\n|b\nc")
t("O", "a\n|c", "Ob<Esc>", "a\n|b\nc")
t("o autoindent", "  |a", "ob<Esc>", "  a\n  |b")
t("3i", "|x", "3iab<Esc>", "ababa|bx")
t("3o", "|x", "3oa<Esc>", "x\na\na\n|a")
t("insert enter", "ab|cd", "i<CR><Esc>", "ab\n|cd")
t("insert bs", "ab|c", "i<BS><BS><Esc>", "|c")
t("insert bs join", "a\n|b", "i<BS><Esc>", "|ab")
t("insert ^w", "foo bar|", "A<C-w>x<Esc>", "foo |x")
t("insert ^u", "foo|", "A bar<C-u>x<Esc>", "foo|x")
t("insert tab et", "|a", "i<Tab><Esc>", "   | a", setup: { $0.opts.expandtab = true; $0.opts.tabstop = 4 })
t("R", "|abcd", "Rxy<Esc>", "x|ycd")
t("R past end", "a|b", "Rxyz<Esc>", "axy|z")
t("R bs", "|abcd", "Rxy<BS><BS><Esc>", "|abcd")
t("insert ^r", "|x", "yiwA <C-r>\"<Esc>", "x |x")

// Yank / put
t("yyp", "|a\nb", "yyp", "a\n|a\nb")
t("yyP", "a\n|b", "yyP", "a\n|b\nb")
t("3p lines", "|a", "yy3p", "a\n|a\na\na")
t("yw p", "|foo bar", "ywP", "foo| foo bar")
t("xp swap", "|ab", "xp", "b|a")
t("ddp swap", "|a\nb", "ddp", "b\n|a")
t("p charwise", "|abc", "yl$p", "abc|a")
t("named register", "|a\nb", "\"xyyj\"xp", "a\nb\n|a")
t("append register", "|a\nb", "\"xyyj\"Xyy\"xP", "a\n|a\nb\nb")
t("numbered", "|a\nb\nc", "dddd\"2p", "c\n|a")
t("yank cursor", "foo |bar", "yb", "|foo bar")
t("yiw", "foo b|ar", "yiw$p", "foo barba|r")
t("black hole", "|a\nb", "yy\"_ddp", "b\n|a")
t("gp", "|a\nb", "yygpix<Esc>", "a\na\n|xb")

// Undo / redo / dot
t("u", "|abc", "xu", "|abc")
t("u twice", "|abc", "xxuu", "|abc")
t("u insert", "|a", "ifoo<Esc>u", "|a")
t("redo", "|abc", "xu<C-r>", "|bc")
t("u o", "|a", "ob<Esc>u", "|a")
t(".", "|abcd", "x..", "|d")
t(". dw", "|a b c d", "dw..", "|d")
t(". insert", "|x", "ia<Esc>.", "|aax")
t(". cw", "|foo foo", "cwbar<Esc>w.", "bar ba|r")
t(". with count", "|abcdef", "x3.", "|ef")
t(". A", "|a\nb", "A;<Esc>j.", "a;\nb|;")
t(". dd", "|a\nb\nc", "dd.", "|c")
t("u after .", "|abc", "x.u", "|bc")
t(". visual", "|abcdef\nabcdef", "vld.", "|ef\nabcdef")
t(". visual line", "|a\nb\nc\nd", "Vjd.", "|")
t(". >>", "|a\nb", ">>j.", "\ta\n\t|b")
t(". o", "|a", "ob<Esc>.", "a\nb\n|b")

// Visual
t("vd", "|abcd", "vld", "|cd")
t("vjd", "a|bc\ndef", "vjd", "a|f")
t("Vd", "a\n|b\nc", "Vd", "a\n|c")
t("Vjd", "|a\nb\nc", "Vjd", "|c")
t("vy", "|abc", "vly$p", "abca|b")
t("vc", "|abcd", "vlcX<Esc>", "|Xcd")
t("v~", "|abc", "vl~", "|ABc")
t("vU", "|abc", "vlU", "|ABc")
t("vu", "|ABC", "vlu", "|abC")
t("V>", "|a\nb", "Vj>", "\t|a\n\tb")
t("vr", "|abcd", "vlrx", "|xxcd")
t("viw", "foo b|ar baz", "viwd", "foo | baz")
t("vi(", "(a|bc)", "vi(d", "(|)")
t("vo", "ab|cd", "vlohd", "|a")
t("vp", "|foo bar", "yiwwviwp", "foo fo|o")
t("Vp", "|a\nb", "yyjVp", "a\n|a")
t("vJ", "|a\nb\nc", "VjjJ", "a b| c")
t("v:", "|a\nb\nc", "Vj:s/$/!/<CR>", "a!\n|b!\nc")
t("gv", "|abc", "vl<Esc>gvd", "|c")
t("v$", "|ab\ncd", "v$d", "|cd")

// Search
t("/", "|foo bar foo", "/foo<CR>", "foo bar |foo")
t("/ wrap", "foo |bar foo", "/bar<CR>", "foo |bar foo")
t("n", "|a x a x a", "/a<CR>n", "a x a x |a")
t("N", "|a x a x a", "/a<CR>N", "|a x a x a")
t("?", "a x a x |a", "?a<CR>", "a x |a x a")
t("*", "|foo bar foo", "*", "foo bar |foo")
t("* word boundary", "|foo foobar foo", "*", "foo foobar |foo")
t("#", "foo bar |foo", "#", "|foo bar foo")
t("d/", "|foo bar baz", "d/baz<CR>", "|baz")
t("c/", "|foo bar baz", "c/bar<CR>X <Esc>", "X| bar baz")
t("d? esc", "foo |bar", "d?foo<Esc>x", "foo |ar")
t("/ regex", "|a1 b22 c333", "/\\d\\{3}<CR>", "a1 b22 c|333")
t("/ word bound", "|cat concat cat", "/\\<cat\\><CR>", "cat concat |cat")
t("ignorecase", "|x FOO", "/foo<CR>", "x |FOO", setup: { $0.opts.ignorecase = true })
t("smartcase", "|x foo Foo", "/Foo<CR>", "x foo |Foo", setup: { $0.opts.ignorecase = true; $0.opts.smartcase = true })
t("dn", "|a x a", "/a<CR>ggdn", "|a")

// Ex
t(":s", "|foo foo", ":s/foo/bar/<CR>", "|bar foo")
t(":s g", "|foo foo", ":s/foo/bar/g<CR>", "|bar bar")
t(":%s", "a\nb\na", ":%s/a/x/<CR>", "x\nb\n|x")
t(":s groups", "|john smith", ":s/\\(\\w\\+\\) \\(\\w\\+\\)/\\2 \\1/<CR>", "|smith john")
t(":s &", "|ab", ":s/b/[&]/<CR>", "|a[b]")
t(":s newline", "|a,b", ":s/,/\\r/<CR>", "a\n|b")
t(":s alt delim", "|a/b", ":s#/#-#<CR>", "|a-b")
t(":s ignorecase flag", "|FOO", ":s/foo/x/i<CR>", "|x")
t(":s empty pat", "|foo bar", "/bar<CR>:s//baz/<CR>", "|foo baz")
t(":range s", "a\na\na\na", ":2,3s/a/b/<CR>", "a\nb\n|b\na")
t(":.,+1", "|a\na\na", ":.,+1s/a/b/<CR>", "b\n|b\na")
t(":'<,'>", "a\n|a\na\na", "Vj:s/a/b/<CR>", "a\nb\n|b\na")
t(":g d", "a1\nb\na2\nc", ":g/a/d<CR>", "b\n|c")
t(":v d", "a1\nb\na2\nc", ":v/a/d<CR>", "a1\n|a2")
t(":g s", "a\nb\na", ":g/a/s/a/x/<CR>", "x\nb\n|x")
t(":g m0", "1\n2\n3", ":g/^/m0<CR>", "|3\n2\n1")
t(":g t$", "a\nb", ":g/a/t$<CR>", "a\nb\n|a")
t(":g normal", "a\nb", ":g/./norm Ax<CR>", "ax\n|bx")
t(":d", "a\n|b\nc", ":d<CR>", "a\n|c")
t(":2,3d", "a\nb\nc\nd", ":2,3d<CR>", "a\n|d")
t(":$", "|a\nb\nc", ":$<CR>", "a\nb\n|c")
t(":2", "|a\nb\nc", ":2<CR>", "a\n|b\nc")
t(":m", "|a\nb\nc", ":m$<CR>", "b\nc\n|a")
t(":m0", "a\nb\n|c", ":m0<CR>", "|c\na\nb")
t(":t.", "|a\nb", ":t.<CR>", "a\n|a\nb")
t(":co0", "a\n|b", ":co0<CR>", "|b\na\nb")
t(":j", "|a\nb\nc", ":j<CR>", "a| b\nc")
t(":1,3j", "a\nb\nc", ":1,3j<CR>", "a b| c")
t(":>", "|a", ":><CR>", "\t|a")
t(":sort", "c\na\nb", ":sort<CR>", "|a\nb\nc")
t(":sort!", "a\nc\nb", ":sort!<CR>", "|c\nb\na")
t(":sort n", "10\n9\n100", ":sort n<CR>", "|9\n10\n100")
t(":sort u", "b\na\nb", ":sort u<CR>", "|a\nb")
t(":y :pu", "|a\nb", ":y<CR>:2pu<CR>", "a\nb\n|a")
t(":norm", "a\nb", ":%norm Ax<CR>", "ax\nb|x")
t(":/pat/", "|a\nb\nc", ":/c/d<CR>", "a\n|b")
t("@:", "a\na\na", ":s/a/b/<CR>j@:", "b\n|b\na")
t("&", "|a a\na a", ":s/a/b/<CR>j&", "b a\n|b a")

// Macros
t("macro", "|1\n2\n3", "qaA!<Esc>jq2@a", "1!\n2!\n3|!")
t("macro @@", "|1\n2\n3", "qaA!<Esc>jq@a@@", "1!\n2!\n3|!")
t("macro paste", "|x", "qaAy<Esc>q\"ap", "xyAy|\u{1B}")
t("macro count", "|a\na\na\na", "qqrbjq3@q", "b\nb\nb\n|b")

// Options / misc
t("set et sw", "|a", ":set et sw=2<CR>>>", "  |a")
t("set nu ok", "|a", ":set nu rnu<CR>x", "|")
t("ZZ modified no name", "|a", "x:x<CR>", "|")
t("text obj quotes on quote", "x |\"ab\" y", "di\"", "x \"|\" y")
t("ci( nested", "f(a, g(b), |c)", "ci(x<Esc>", "f(|x)")
t("yi{ multiline", "{\n  |a\n}", "yi{Gp", "{\n  a\n}\n  |a")
t("count via :", "|a\nb\nc\nd", "2:d<CR>", "|c\nd")
t("dd then u cursor", "a\n|b\nc", "ddu", "a\n|b\nc")
t("^d", (1...50).map { "l\($0)" }.joined(separator: "\n"), "<C-d>", (1...50).map { $0 == 11 ? "|l\($0)" : "l\($0)" }.joined(separator: "\n"))
t("tabs display j", "\t|x\nabcdefghij", "j", "\tx\nabcdefgh|ij")

// File round-trip
do {
    let dir = NSTemporaryDirectory() + "vikit-test-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/a.txt"
    try "one\ntwo\n".write(toFile: path, atomically: true, encoding: .utf8)
    let e = ViEngine()
    e.openFile(path)
    e.feed(parseKeyNotation("ddpAx<Esc>:w<CR>"))
    let back = try String(contentsOfFile: path, encoding: .utf8)
    if back == "two\nonex\n" && !e.modified { passes += 1 } else { failures += 1; print("FAIL [file write] got \(back.debugDescription) modified=\(e.modified) msg=\(e.message)") }
    e.feed(parseKeyNotation("x:q<CR>"))
    if e.message.hasPrefix("E37") { passes += 1 } else { failures += 1; print("FAIL [E37] \(e.message)") }
    var quit = false
    e.onQuit = { quit = true }
    e.feed(parseKeyNotation(":q!<CR>"))
    if quit { passes += 1 } else { failures += 1; print("FAIL [q!]") }
    e.feed(parseKeyNotation(":e!<CR>"))
    if e.lines.map({ String($0) }) == ["two", "onex"] && !e.modified { passes += 1 } else { failures += 1; print("FAIL [e!] \(e.lines) \(e.message)") }
    // DOS line endings preserved
    try "a\r\nb\r\n".write(toFile: path, atomically: true, encoding: .utf8)
    e.openFile(path)
    e.feed(parseKeyNotation("Ax<Esc>:w<CR>"))
    let dos = try String(contentsOfFile: path, encoding: .utf8)
    if dos == "ax\r\nb\r\n" { passes += 1 } else { failures += 1; print("FAIL [dos] \(dos.debugDescription)") }
    // :w newfile, :r
    e.feed(parseKeyNotation(":w \(dir)/b.txt<CR>:r \(dir)/b.txt<CR>"))
    if e.lines.map({ String($0) }) == ["ax", "ax", "b", "b"] { passes += 1 } else { failures += 1; print("FAIL [:r] \(e.lines.map { String($0) }) \(e.message)") }
    // undo stack: u after many edits returns to original
    let e2 = ViEngine()
    e2.load(text: "hello world")
    e2.feed(parseKeyNotation("dwAx<Esc>0~:s/x/y/<CR>uuuu"))
    if e2.lines.map({ String($0) }) == ["hello world"] && !e2.modified { passes += 1 } else { failures += 1; print("FAIL [undo chain] \(e2.lines.map { String($0) }) modified=\(e2.modified)") }
    try? FileManager.default.removeItem(atPath: dir)
} catch {
    failures += 1
    print("FAIL [file tests] \(error)")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
