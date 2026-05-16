import AppKit
import UniformTypeIdentifiers

@MainActor
enum OpenPanelCoordinator {
    static func runPairPicker() -> PhotoPair? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.message = "Select an ARW + HIF pair (or a folder containing one)"
        panel.prompt = "Open"

        var types: [UTType] = [.image]
        if let arw = UTType(filenameExtension: "arw") { types.append(arw) }
        if let hif = UTType(filenameExtension: "hif") { types.append(hif) }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK else { return nil }
        return PairFinder.firstPair(in: PairFinder.expand(panel.urls))
    }
}
