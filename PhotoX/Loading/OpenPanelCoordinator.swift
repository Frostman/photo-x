import AppKit
import UniformTypeIdentifiers

@MainActor
enum OpenPanelCoordinator {
    /// Opens a folder or a set of files and returns (shoot, focus entry).
    static func runShootPicker() -> (shoot: Shoot, focus: PhotoEntry)? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.message = "Pick a folder of ARW + HIF/JPG pairs (or any preview inside one)"
        panel.prompt = "Open"
        panel.canCreateDirectories = false

        var types: [UTType] = [.image, .folder]
        if let arw  = UTType(filenameExtension: "arw")  { types.append(arw) }
        if let hif  = UTType(filenameExtension: "hif")  { types.append(hif) }
        if let jpg  = UTType(filenameExtension: "jpg")  { types.append(jpg) }
        if let jpeg = UTType(filenameExtension: "jpeg") { types.append(jpeg) }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK else { return nil }
        return ShootScanner.resolve(droppedURLs: panel.urls)
    }
}
