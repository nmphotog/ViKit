// App.swift — application, scene and view-controller glue for ViKit (Mac Catalyst / UIKit).

import UIKit
import UniformTypeIdentifiers

let openActivityType = "dev.vikit.open"

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // `--cwd` from the `vikit` launcher, else the directory chosen in Settings (default: home).
        Preferences.applyAtLaunch(arguments: CommandLine.arguments)
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .format)
        builder.remove(menu: .newScene)
        builder.remove(menu: .toolbar)

        let settings = UIKeyCommand(title: "Settings…", action: #selector(EditorViewController.showSettings(_:)), input: ",", modifierFlags: .command)
        builder.insertSibling(UIMenu(title: "", identifier: UIMenu.Identifier("dev.vikit.settings"), options: .displayInline, children: [settings]), afterMenu: .about)

        let newWindow = UIKeyCommand(title: "New Window", action: #selector(EditorViewController.newWindow(_:)), input: "n", modifierFlags: .command)
        let open = UIKeyCommand(title: "Open…", action: #selector(EditorViewController.openDocument(_:)), input: "o", modifierFlags: .command)
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [newWindow, open]), atStartOfMenu: .file)

        let save = UIKeyCommand(title: "Save", action: #selector(EditorViewController.saveDocument(_:)), input: "s", modifierFlags: .command)
        let saveAs = UIKeyCommand(title: "Save As…", action: #selector(EditorViewController.saveDocumentAs(_:)), input: "s", modifierFlags: [.command, .shift])
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [save, saveAs]), atEndOfMenu: .file)

        let bigger = UIKeyCommand(title: "Bigger", action: #selector(EditorViewController.increaseFontSize(_:)), input: "+", modifierFlags: .command)
        let biggerAlt = UIKeyCommand(title: "Bigger", action: #selector(EditorViewController.increaseFontSize(_:)), input: "=", modifierFlags: .command, propertyList: "alt")
        biggerAlt.attributes = .hidden
        let smaller = UIKeyCommand(title: "Smaller", action: #selector(EditorViewController.decreaseFontSize(_:)), input: "-", modifierFlags: .command)
        let actual = UIKeyCommand(title: "Actual Size", action: #selector(EditorViewController.resetFontSize(_:)), input: "0", modifierFlags: .command)
        let toggleNumbers = UICommand(title: "Line Numbers", action: #selector(EditorViewController.toggleLineNumbers(_:)))
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [bigger, biggerAlt, smaller, actual, toggleNumbers]), atStartOfMenu: .view)

        let help = UICommand(title: "ViKit Quick Reference", action: #selector(EditorViewController.showViHelp(_:)))
        builder.replaceChildren(ofMenu: .help) { _ in [help] }
    }
}

@objc(SceneDelegate)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private static var consumedLaunchArguments = false

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 420, height: 260)
        let vc = EditorViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window

        if let titlebar = windowScene.titlebar {
            titlebar.titleVisibility = .visible
            titlebar.toolbar = nil
            titlebar.separatorStyle = .line
        }

        var path: String?
        if let a = connectionOptions.userActivities.first(where: { $0.activityType == openActivityType }) {
            path = a.userInfo?["path"] as? String
        } else if let url = connectionOptions.urlContexts.first?.url {
            path = url.path
        } else if !SceneDelegate.consumedLaunchArguments {
            SceneDelegate.consumedLaunchArguments = true
            path = SceneDelegate.fileArgument()
        }
        if let path { vc.open(path: path) }
        vc.updateTitle()

        if session.stateRestorationActivity == nil {
            let frame = CGRect(x: 0, y: 0, width: 960, height: 680)
            windowScene.requestGeometryUpdate(.Mac(systemFrame: frame)) { _ in }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let vc = window?.rootViewController as? EditorViewController else { return }
        for ctx in URLContexts { vc.openHereOrInNewWindow(path: ctx.url.path) }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == openActivityType, let p = userActivity.userInfo?["path"] as? String,
              let vc = window?.rootViewController as? EditorViewController else { return }
        vc.openHereOrInNewWindow(path: p)
    }

    /// First non-flag command-line argument (skips `-Flag value` pairs added by macOS / Xcode).
    private static func fileArgument() -> String? {
        var args = Array(CommandLine.arguments.dropFirst())
        while let a = args.first {
            args.removeFirst()
            if a == "--cwd" { if !args.isEmpty { args.removeFirst() }; continue }
            if a.hasPrefix("-psn_") { continue }
            if a.hasPrefix("-") { if let n = args.first, !n.hasPrefix("-") { args.removeFirst() }; continue }
            return a
        }
        return nil
    }
}

final class EditorViewController: UIViewController, UIDocumentPickerDelegate {
    let engine = ViEngine()
    private var textView: ViTextView!
    private enum PickerPurpose { case open, saveAs }
    private var pickerPurpose: PickerPurpose = .open
    private var quitAfterSave = false

    override func loadView() {
        textView = ViTextView(engine: engine)
        view = textView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        engine.loadRC()
        engine.onQuit = { [weak self] in self?.closeWindow() }
        engine.onSaveAs = { [weak self] in self?.presentSaveAs() }
        engine.onBell = { [weak self] in self?.textView.flashBell() }
        engine.clipboardGet = { UIPasteboard.general.string }
        engine.clipboardSet = { UIPasteboard.general.string = $0 }
        textView.onStateChange = { [weak self] in self?.updateTitle() }
        NotificationCenter.default.addObserver(forName: .viKitDirectoryChanged, object: nil, queue: .main) { [weak self] _ in
            self?.textView.setNeedsDisplay()   // file names in the status bar are shown relative to it
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = textView.becomeFirstResponder()
        updateTitle()
        promptForFileNameIfNeeded()
        runTestScriptIfRequested()
    }

    // MARK: Name-your-file prompt

    private weak var namePrompt: UIAlertController?
    private var namePromptCreate: ((String) -> Void)?

    /// A window with no file must be given one before editing: ask for a name (or open an existing file).
    private func promptForFileNameIfNeeded(error: String? = nil) {
        guard engine.filePath == nil, !engine.modified, presentedViewController == nil else { return }
        let env = ProcessInfo.processInfo.environment
        if env["VIKIT_TEST_KEYS"] != nil && env["VIKIT_TEST_NAMEPROMPT"] == nil { return }

        let dir = Preferences.abbreviate(FileManager.default.currentDirectoryPath)
        var message = "Name the file to start editing. A plain name is saved in \(dir)."
        if let error { message = error + "\n\n" + message }
        let alert = UIAlertController(title: "New File", message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "untitled.txt"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
        }
        let create = UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            self?.createNamedFile(alert?.textFields?.first?.text ?? "")
        }
        create.isEnabled = false
        if let field = alert.textFields?.first {
            field.addAction(UIAction { [weak field, weak create] _ in
                create?.isEnabled = !(field?.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }, for: .editingChanged)
        }
        alert.addAction(create)
        alert.addAction(UIAlertAction(title: "Open Existing…", style: .default) { [weak self] _ in
            self?.openDocument(nil)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.closeWindow()
        })
        alert.preferredAction = create
        namePrompt = alert
        namePromptCreate = { [weak self, weak alert] name in
            alert?.dismiss(animated: false)
            self?.createNamedFile(name)
        }
        present(alert, animated: true)
    }

    private func createNamedFile(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { promptAgain(error: nil); return }
        let path = ViEngine.expandPath(name)
        let parent = (path as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            promptAgain(error: "“\(name)” is a folder. Type a file name.")
        } else if !(FileManager.default.fileExists(atPath: parent, isDirectory: &isDir) && isDir.boolValue) {
            promptAgain(error: "The folder “\(Preferences.abbreviate(parent))” doesn't exist.")
        } else {
            open(path: path)   // an existing file is opened; a new one shows [New] until :w
            _ = textView.becomeFirstResponder()
        }
    }

    /// Re-shows the prompt once the previous dialog (or picker) has finished closing.
    private func promptAgain(error: String?, attempts: Int = 30) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if self.presentedViewController != nil {
                let closing = self.presentedViewController?.isBeingDismissed == true || self.presentedViewController === self.namePrompt
                if attempts > 0 && closing {
                    self.promptAgain(error: error, attempts: attempts - 1)
                }
                return
            }
            self.promptForFileNameIfNeeded(error: error)
        }
    }

    /// Test hook: VIKIT_TEST_KEYS="..." feeds keys (vim <> notation, "|" separates snapshot steps);
    /// VIKIT_TEST_SNAPSHOT=/path/prefix writes prefix-N.png after each step; the app then exits.
    private func runTestScriptIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let script = env["VIKIT_TEST_KEYS"], let prefix = env["VIKIT_TEST_SNAPSHOT"] else { return }
        if env["VIKIT_TEST_DARK"] != nil { view.window?.overrideUserInterfaceStyle = .dark }
        let steps = script.components(separatedBy: "|")
        func run(_ i: Int) {
            if i >= steps.count { exit(0) }
            if steps[i] == "@settings" { showSettings(nil) }
            else if steps[i].hasPrefix("@name:") { namePromptCreate?(String(steps[i].dropFirst(6))) }
            else { textView.send(parseKeyNotation(steps[i])) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                let target: UIView = presentedViewController?.view ?? view.window ?? textView
                let r = UIGraphicsImageRenderer(bounds: target.bounds)
                let img = r.image { _ in target.drawHierarchy(in: target.bounds, afterScreenUpdates: true) }
                try? img.pngData()?.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
                run(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { run(0) }
    }

    func open(path: String) {
        namePrompt?.dismiss(animated: false)
        engine.openFile(path)
        textView.setNeedsLayout()
        textView.setNeedsDisplay()
        updateTitle()
    }

    /// Load into this window if it holds an untouched empty buffer, otherwise open a new window.
    func openHereOrInNewWindow(path: String) {
        let pristine = engine.filePath == nil && !engine.modified && engine.lines.count == 1 && engine.lines[0].isEmpty
        if pristine || engine.filePath == ViEngine.expandPath(path) && !engine.modified {
            open(path: path)
        } else {
            let activity = NSUserActivity(activityType: openActivityType)
            activity.userInfo = ["path": path]
            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil)
        }
    }

    func updateTitle() {
        guard let scene = view.window?.windowScene else { return }
        let name = engine.filePath.map { ($0 as NSString).lastPathComponent } ?? "Untitled"
        scene.title = engine.modified ? "\(name) — Edited" : name
        if let p = engine.filePath {
            let dir = (p as NSString).deletingLastPathComponent
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            scene.subtitle = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
        } else {
            scene.subtitle = ""
        }
    }

    private func closeWindow() {
        guard let scene = view.window?.windowScene else { exit(0) }
        let others = UIApplication.shared.connectedScenes.filter { $0 !== scene && $0 is UIWindowScene }
        if others.isEmpty { exit(0) }
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
    }

    // MARK: Menu actions

    @objc func newWindow(_ sender: Any?) {
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        if let p = engine.filePath { picker.directoryURL = URL(fileURLWithPath: (p as NSString).deletingLastPathComponent) }
        pickerPurpose = .open
        present(picker, animated: true)
    }

    @objc func saveDocument(_ sender: Any?) {
        if engine.filePath == nil { presentSaveAs(); return }
        textView.send(parseKeyNotation("<Esc>:w<CR>"))
    }

    @objc func saveDocumentAs(_ sender: Any?) { presentSaveAs() }

    @objc func increaseFontSize(_ sender: Any?) { textView.setFontSize(textView.fontSize + 1) }
    @objc func decreaseFontSize(_ sender: Any?) { textView.setFontSize(textView.fontSize - 1) }
    @objc func resetFontSize(_ sender: Any?) { textView.setFontSize(14) }
    @objc func toggleLineNumbers(_ sender: Any?) {
        engine.opts.number.toggle()
        textView.setNeedsLayout()
        textView.setNeedsDisplay()
    }
    @objc func showSettings(_ sender: Any?) {
        if presentedViewController is SettingsViewController { return }
        let settings = SettingsViewController()
        settings.modalPresentationStyle = .formSheet
        present(settings, animated: true)
    }
    @objc func showViHelp(_ sender: Any?) {
        engine.pager = ViEngine.helpText
        textView.setNeedsDisplay()
    }

    private func presentSaveAs() {
        let name = engine.filePath.map { ($0 as NSString).lastPathComponent } ?? "Untitled.txt"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(name)
            try Data(engine.bufferText().utf8).write(to: tmp)
            let picker = UIDocumentPickerViewController(forExporting: [tmp], asCopy: false)
            picker.delegate = self
            pickerPurpose = .saveAs
            present(picker, animated: true)
        } catch {
            engine.setError("E212: Can't prepare file for saving: \(error.localizedDescription)")
            textView.setNeedsDisplay()
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        switch pickerPurpose {
        case .open:
            for url in urls {
                _ = url.startAccessingSecurityScopedResource()
                openHereOrInNewWindow(path: url.path)
            }
        case .saveAs:
            if let url = urls.first {
                engine.markSaved(path: url.path)
            }
        }
        textView.setNeedsDisplay()
        updateTitle()
        _ = textView.becomeFirstResponder()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        _ = textView.becomeFirstResponder()
        if pickerPurpose == .open { promptAgain(error: nil) }   // still needs a file
    }
}
