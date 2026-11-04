# ViKit — vi for macOS, built with UIKit

A native Mac app (Mac Catalyst, "Optimize for Mac" idiom) that implements a vi/vim editor
with a custom-drawn UIKit view. No Xcode project needed: it builds with `swiftc`.

```
./build.sh --test --install   # run 247 engine tests, build, install to ~/Applications
./vikit file.txt              # open a file from the shell (uses the installed app)
```
After `--install`, ViKit is a normal app: open it from Finder, Spotlight, Launchpad or the
Dock, or use **Open With → ViKit** on a text file. The icon is drawn by
`swift tools/make-icon.swift` (then `iconutil` → `Resources/AppIcon.icns`).

A new window (⌘N, or launching without a file) asks you to **name the file** first. A plain
name goes in the working directory; `~/path` and absolute paths work too. You can also open an
existing file from there, or Cancel to close the window. A new file is written on `:w`.

**ViKit → Settings… (⌘,)** sets the working directory that relative paths (`:e`, `:w`, `:r`)
start from; it's remembered between launches. By default, starting from the `vikit` command
uses your terminal's directory instead (there's a checkbox to turn that off). `:cd` changes it
for the current run only.

## Layout
- `Sources/ViEngine.swift` — the whole editor (modes, parser, motions, operators, text objects,
  registers, macros, undo/redo, dot-repeat, search, ex commands). Foundation only.
- `Sources/ViTextView.swift` — UIKit view: drawing, hardware keys (`pressesBegan`), key repeat,
  mouse click/drag-select, trackpad scrolling, clipboard.
- `Sources/App.swift` — app/scene delegates, menus (⌘O ⌘S ⇧⌘S ⌘N ⌘+ ⌘-), document pickers.
- `Sources/Settings.swift` — Settings window and saved preferences.
- `tools/make-icon.swift` — draws the app icon.
- `Tests/main.swift` — headless engine tests (`./test.sh`).

Type `:help` in the app for the full command list. Options from `set` lines in
`~/.exrc`, `~/.vimrc` and `~/.vikitrc` are applied.

## Not supported (yet)
Syntax highlighting, soft wrap (long lines scroll horizontally), splits/multiple buffers
(use windows), visual-block mode, `:!` shell commands, sentence motions, search offsets.
