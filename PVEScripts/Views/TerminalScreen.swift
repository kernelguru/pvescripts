import SwiftUI
import SwiftTerm
import UIKit

struct TerminalScreen: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var confirmClose = false
    @State private var keyboardFocus = KeyboardFocus()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                TerminalHostView(session: session, fontSize: settings.terminalFontSize, focus: keyboardFocus)
                    .background(SwiftUI.Color.black)
                    .ignoresSafeArea(.container, edges: .bottom)
                KeyBar(session: session, focus: keyboardFocus)
            }
            .background(SwiftUI.Color.black)
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") {
                        if session.state == .connected { confirmClose = true } else { close() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if session.state == .closed || isFailed {
                        Button {
                            session.start()
                        } label: {
                            Label("Neu verbinden", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .confirmationDialog("Verbindung trennen?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Trennen", role: .destructive) { close() }
            } message: {
                Text("Ein laufendes Script wird beim Trennen der SSH-Sitzung abgebrochen.")
            }
            .alert(item: $session.hostKeyPrompt) { prompt in
                Alert(
                    title: Text(prompt.changed ? "Host-Schlüssel geändert!" : "Unbekannter Host"),
                    message: Text(prompt.changed
                        ? "Der Schlüssel von \(session.host.address) stimmt nicht mehr mit dem gespeicherten überein. Das kann nach einer Neuinstallation normal sein – oder auf einen Angriff hindeuten.\n\n\(prompt.fingerprint)"
                        : "Die Echtheit von \(session.host.address) kann nicht bestätigt werden. Vergleiche den Fingerprint mit `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` auf dem Host.\n\n\(prompt.fingerprint)"),
                    primaryButton: .default(Text(prompt.changed ? "Neuen Schlüssel vertrauen" : "Vertrauen & verbinden")) {
                        session.acceptHostKey(prompt)
                    },
                    secondaryButton: .cancel(Text("Abbrechen")) {
                        session.rejectHostKey()
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Display anlassen, damit die SSH-Sitzung während der Installation nicht abbricht.
            UIApplication.shared.isIdleTimerDisabled = true
            if session.state == .idle && session.hostKeyPrompt == nil { session.start() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.disconnect()
        }
    }

    private var isFailed: Bool {
        if case .failed = session.state { return true }
        return false
    }

    private func close() {
        session.disconnect()
        dismiss()
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(session.host.endpoint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(SwiftUI.Color(white: 0.08))
    }

    private var statusColor: SwiftUI.Color {
        switch session.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle, .closed: .gray
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: "Bereit"
        case .connecting: "Verbinde …"
        case .connected: session.terminalTitle.isEmpty ? "Verbunden" : session.terminalTitle
        case .closed: "Getrennt"
        case .failed(let message): message
        }
    }
}

/// Hält eine Referenz auf die TerminalView, damit die Tastenleiste die Tastatur ein-/ausblenden kann.
final class KeyboardFocus {
    weak var view: TerminalView?

    func toggle() {
        guard let view else { return }
        if view.isFirstResponder { _ = view.resignFirstResponder() } else { _ = view.becomeFirstResponder() }
    }
}

struct TerminalHostView: UIViewRepresentable {
    let session: TerminalSession
    let fontSize: Double
    let focus: KeyboardFocus

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        view.backgroundColor = .black
        view.optionAsMetaKey = true
        // Eigene Tastenleiste (KeyBar) statt der SwiftTerm-Zubehörleiste.
        view.inputAccessoryView = nil
        focus.view = view
        session.terminalView = view
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if abs(view.font.pointSize - fontSize) > 0.1 {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession

        init(session: TerminalSession) { self.session = session }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in session.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            Task { @MainActor in session.terminalTitle = title }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in session.send(bytes) }
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            DispatchQueue.main.async { UIApplication.shared.open(url) }
        }

        func bell(source: TerminalView) {
            DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                DispatchQueue.main.async { UIPasteboard.general.string = text }
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Tastenleiste für Whiptail-Menüs: Pfeile, Tab, Leertaste, Enter, Esc, Strg-C.
struct KeyBar: View {
    @ObservedObject var session: TerminalSession
    let focus: KeyboardFocus

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key(systemImage: "keyboard") { focus.toggle() }
                key("Esc") { session.send([0x1b]) }
                key("Tab") { session.send([0x09]) }
                key(systemImage: "arrow.up") { session.send(arrow("A")) }
                key(systemImage: "arrow.down") { session.send(arrow("B")) }
                key(systemImage: "arrow.left") { session.send(arrow("D")) }
                key(systemImage: "arrow.right") { session.send(arrow("C")) }
                key("Space") { session.send([0x20]) }
                key(systemImage: "return") { session.send([0x0d]) }
                key("^C") { session.send([0x03]) }
                key("^D") { session.send([0x04]) }
                key("y") { session.send(Array("y".utf8)) }
                key("n") { session.send(Array("n".utf8)) }
                key(systemImage: "doc.on.clipboard") {
                    if let text = UIPasteboard.general.string { session.send(text: text) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(SwiftUI.Color(white: 0.1))
        .disabled(session.state != .connected)
        .opacity(session.state == .connected ? 1 : 0.5)
    }

    /// Pfeiltasten im Application-Cursor-Modus senden, wenn das Programm ihn aktiviert hat.
    private func arrow(_ letter: Character) -> [UInt8] {
        let app = focus.view?.getTerminal().applicationCursor ?? false
        return [0x1b, app ? 0x4f : 0x5b, letter.asciiValue!]
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            action()
        }) {
            Text(title)
                .font(.callout.monospaced().weight(.medium))
                .frame(minWidth: 44, minHeight: 36)
                .padding(.horizontal, 4)
                .background(SwiftUI.Color(white: 0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func key(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            action()
        }) {
            Image(systemName: systemImage)
                .font(.callout.weight(.medium))
                .frame(minWidth: 44, minHeight: 36)
                .background(SwiftUI.Color(white: 0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
