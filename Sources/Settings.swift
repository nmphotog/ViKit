// Settings.swift — ViKit preferences (⌘,): the working directory used for relative paths.

import UIKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let viKitDirectoryChanged = Notification.Name("ViKitDirectoryChanged")
}

enum Preferences {
    private static let dirKey = "ViKitWorkingDirectory"
    private static let terminalKey = "ViKitUseTerminalDirectory"

    static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }

    /// The saved working directory, or nil for the home folder.
    static var workingDirectory: String? {
        get { UserDefaults.standard.string(forKey: dirKey) }
        set { UserDefaults.standard.set(newValue, forKey: dirKey) }
    }

    /// When launched through the `vikit` command, start in the shell's directory instead.
    static var useTerminalDirectory: Bool {
        get { UserDefaults.standard.object(forKey: terminalKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: terminalKey) }
    }

    /// Directory to start in: the saved one if it still exists, otherwise home.
    static var startDirectory: String {
        var isDir: ObjCBool = false
        if let d = workingDirectory, FileManager.default.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue { return d }
        return home
    }

    /// Applies the launch-time working directory (`--cwd` from the launcher, else the preference).
    static func applyAtLaunch(arguments args: [String]) {
        if useTerminalDirectory, let i = args.firstIndex(of: "--cwd"), i + 1 < args.count,
           FileManager.default.changeCurrentDirectoryPath(args[i + 1]) { return }
        FileManager.default.changeCurrentDirectoryPath(startDirectory)
    }

    /// Changes the saved directory and the app's current directory, then refreshes all windows.
    static func setWorkingDirectory(_ path: String?) {
        workingDirectory = path
        FileManager.default.changeCurrentDirectoryPath(startDirectory)
        NotificationCenter.default.post(name: .viKitDirectoryChanged, object: nil)
    }

    static func abbreviate(_ path: String) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

final class SettingsViewController: UIViewController, UIDocumentPickerDelegate {
    private let savedLabel = UILabel()
    private let currentLabel = UILabel()
    private let homeButton = UIButton(configuration: .bordered())
    private let terminalSwitch = UISwitch()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 560, height: 330)

        let heading = UILabel()
        heading.text = "Working Directory"
        heading.font = .preferredFont(forTextStyle: .headline)

        let explain = UILabel()
        explain.text = "Relative paths in :e, :w, :r and file-name completion start here. Changing it applies to all open windows right away."
        explain.font = .preferredFont(forTextStyle: .footnote)
        explain.textColor = .secondaryLabel
        explain.numberOfLines = 0

        savedLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        savedLabel.lineBreakMode = .byTruncatingMiddle
        let pathBox = UIView()
        pathBox.backgroundColor = .secondarySystemBackground
        pathBox.layer.cornerRadius = 6
        savedLabel.translatesAutoresizingMaskIntoConstraints = false
        pathBox.addSubview(savedLabel)
        NSLayoutConstraint.activate([
            savedLabel.leadingAnchor.constraint(equalTo: pathBox.leadingAnchor, constant: 10),
            savedLabel.trailingAnchor.constraint(equalTo: pathBox.trailingAnchor, constant: -10),
            savedLabel.topAnchor.constraint(equalTo: pathBox.topAnchor, constant: 7),
            savedLabel.bottomAnchor.constraint(equalTo: pathBox.bottomAnchor, constant: -7),
        ])

        let choose = UIButton(configuration: .borderedProminent())
        choose.setTitle("Choose Folder…", for: .normal)
        choose.addTarget(self, action: #selector(chooseFolder), for: .touchUpInside)
        homeButton.setTitle("Use Home Folder", for: .normal)
        homeButton.addTarget(self, action: #selector(useHome), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [choose, homeButton, UIView()])
        buttons.spacing = 8

        let terminalLabel = UILabel()
        terminalLabel.text = "When opened with the vikit command, use the terminal's directory instead"
        terminalLabel.font = .preferredFont(forTextStyle: .body)
        terminalLabel.numberOfLines = 0
        terminalSwitch.addTarget(self, action: #selector(toggleTerminal), for: .valueChanged)
        let terminalRow = UIStackView(arrangedSubviews: [terminalSwitch, terminalLabel])
        terminalRow.spacing = 10
        terminalRow.alignment = .center

        currentLabel.font = .preferredFont(forTextStyle: .footnote)
        currentLabel.textColor = .secondaryLabel
        currentLabel.lineBreakMode = .byTruncatingMiddle

        let done = UIButton(configuration: .bordered())
        done.setTitle("Done", for: .normal)
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        let footer = UIStackView(arrangedSubviews: [currentLabel, done])
        footer.alignment = .center
        footer.spacing = 12

        let stack = UIStackView(arrangedSubviews: [heading, explain, pathBox, buttons, terminalRow, UIView(), footer])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(16, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        addKeyCommand(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close)))
        refresh()
    }

    private func refresh() {
        savedLabel.text = Preferences.abbreviate(Preferences.startDirectory)
        homeButton.isEnabled = Preferences.workingDirectory != nil
        terminalSwitch.isOn = Preferences.useTerminalDirectory
        currentLabel.text = "Current directory: " + Preferences.abbreviate(FileManager.default.currentDirectoryPath)
    }

    @objc private func chooseFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.directoryURL = URL(fileURLWithPath: Preferences.startDirectory)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        _ = url.startAccessingSecurityScopedResource()
        Preferences.setWorkingDirectory(url.standardizedFileURL.path)
        refresh()
    }

    @objc private func useHome() {
        Preferences.setWorkingDirectory(nil)
        refresh()
    }

    @objc private func toggleTerminal() {
        Preferences.useTerminalDirectory = terminalSwitch.isOn
    }

    @objc private func close() { dismiss(animated: true) }
}
