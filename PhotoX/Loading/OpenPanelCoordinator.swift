import AppKit
import UniformTypeIdentifiers

@MainActor
enum OpenPanelCoordinator {
    /// Opens a folder or a set of files and returns (shoot, focus pair).
    static func runShootPicker() -> (shoot: Shoot, focus: PhotoPair)? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.message = "Pick a folder of ARW + HIF pairs, or any pair inside one"
        panel.prompt = "Open"

        var types: [UTType] = [.image, .folder]
        if let arw = UTType(filenameExtension: "arw") { types.append(arw) }
        if let hif = UTType(filenameExtension: "hif") { types.append(hif) }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK else { return nil }
        return ShootScanner.resolve(droppedURLs: panel.urls)
    }
}
