#if os(macOS)
import AppKit

enum FolderPicker {
    /// Shows an NSOpenPanel restricted to folders (new folders allowed) and
    /// calls `completion` with the chosen path on OK.
    static func pick(prompt: String, message: String, initialPath: String? = nil, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        if let initialPath, !initialPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (initialPath as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        panel.begin { response in
            guard response == .OK, let path = panel.url?.path else { return }
            completion(path)
        }
    }
}
#endif
