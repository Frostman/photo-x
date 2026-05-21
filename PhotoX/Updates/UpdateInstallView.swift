import AppKit
import SwiftUI
import WebKit

/// The custom popup body. Mimics Sparkle's standard "Update
/// Available" sheet visually — app icon + version banner + scrollable
/// release-notes pane + tight button bar — but exposes only Cancel /
/// Install and transitions in-place through the download / extract /
/// install stages. Hosted by `UpdateInstallWindowController`; read-
/// only against the view model (mutated by the user driver).
struct UpdateInstallView: View {
    @Bindable var model: UpdateInstallViewModel
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            releaseNotes
            switch model.stage {
            case .available:
                EmptyView()
            case .downloading, .extracting, .installing:
                progressSection
            }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("A new version of PhotoX is available")
                    .font(.title3.bold())
                Text(versionPrompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var versionPrompt: String {
        let currentSuffix = model.currentVersion.isEmpty
            ? ""
            : " You're currently on \(model.currentVersion)."
        switch model.stage {
        case .available:
            return "PhotoX \(model.newVersion) is now available.\(currentSuffix) Would you like to install it?"
        case .downloading:
            return "Downloading PhotoX \(model.newVersion)…"
        case .extracting:
            return "Preparing PhotoX \(model.newVersion)…"
        case .installing:
            return "Installing PhotoX \(model.newVersion) — the app will relaunch in a moment."
        }
    }

    @ViewBuilder
    private var releaseNotes: some View {
        Text("Release notes")
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)
        ReleaseNotesView(html: model.releaseNotesHTML, failed: model.releaseNotesFailed)
            .frame(minHeight: 200, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.progressIndeterminate {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                let value: Double = (model.stage == .downloading)
                    ? model.downloadFraction
                    : model.extractionProgress
                ProgressView(value: value)
                    .progressViewStyle(.linear)
            }
            Text(model.progressLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.stage {
        case .available:
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(!model.actionsEnabled)
            Button("Install Update", action: onInstall)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.actionsEnabled)
        case .downloading, .extracting:
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(!model.actionsEnabled)
        case .installing:
            // App is about to terminate. Buttons would be misleading.
            EmptyView()
        }
    }
}

/// Wraps `WKWebView` so the release-notes pane can render HTML from
/// the appcast description. The appcast typically embeds an `<ul>` of
/// bullet items; falling back to plain text would lose the structure.
private struct ReleaseNotesView: NSViewRepresentable {
    let html: Data?
    let failed: Bool

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // Defensive — we render only the appcast's own HTML, no JS.
        let prefs = WKPreferences()
        if #available(macOS 11, *) {
            cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        } else {
            prefs.javaScriptEnabled = false
        }
        cfg.preferences = prefs
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if let html, !html.isEmpty {
            let body = String(data: html, encoding: .utf8) ?? ""
            view.loadHTMLString(wrap(body), baseURL: nil)
        } else if failed {
            view.loadHTMLString(wrap("<p><em>Release notes are unavailable.</em></p>"), baseURL: nil)
        } else {
            view.loadHTMLString(wrap("<p><em>Loading release notes…</em></p>"), baseURL: nil)
        }
    }

    /// Wrap the appcast HTML with a stylesheet that picks up the
    /// current system appearance so the notes don't look like a
    /// foreign web page floating in a native window.
    private func wrap(_ inner: String) -> String {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fg = dark ? "#e8e8e8" : "#1d1d1f"
        let bg = dark ? "#1f1f1f" : "#ffffff"
        let link = dark ? "#6da7ff" : "#0a66c2"
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
          html, body { margin: 0; padding: 12px; background: \(bg); color: \(fg);
                       font: -apple-system-body; line-height: 1.5; }
          h1, h2, h3, h4 { line-height: 1.25; margin: 18px 0 8px; }
          p, li { margin: 6px 0; }
          ul, ol { padding-left: 22px; }
          a { color: \(link); text-decoration: none; }
          a:hover { text-decoration: underline; }
          code, pre { font: 12.5px / 1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }
          pre { background: rgba(127,127,127,0.12); padding: 8px 10px; border-radius: 4px;
                overflow-x: auto; }
        </style></head><body>\(inner)</body></html>
        """
    }
}
