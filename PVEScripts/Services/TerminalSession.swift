import Foundation
import Citadel
import NIOCore
import NIOSSH
import SwiftTerm

/// Eine interaktive SSH-Shell mit PTY, die an eine SwiftTerm-`TerminalView` gekoppelt ist.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closed
        case failed(String)
    }

    struct HostKeyPrompt: Identifiable, Equatable {
        let id = UUID()
        let key: String
        let fingerprint: String
        let changed: Bool
    }

    let id = UUID()
    let host: ProxmoxHost
    let title: String
    /// Befehl, der nach dem Login automatisch in die Shell geschrieben wird.
    let initialCommand: String?

    @Published private(set) var state: State = .idle
    @Published var hostKeyPrompt: HostKeyPrompt?
    @Published var terminalTitle: String = ""

    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private var pendingOutput: [UInt8] = []
    private var cols = 80
    private var rows = 24

    weak var terminalView: TerminalView? {
        didSet { flushPending() }
    }

    /// Callback, um einen neu vertrauten Host-Schlüssel zu speichern.
    var onTrustHostKey: ((String) -> Void)?

    init(host: ProxmoxHost, title: String, initialCommand: String?) {
        self.host = host
        self.title = title
        self.initialCommand = initialCommand
    }

    var isActive: Bool { state == .connecting || state == .connected }

    // MARK: - Lifecycle

    func start(trustedKeyOverride: String? = nil) {
        guard !isActive else { return }
        state = .connecting
        var host = self.host
        if let trustedKeyOverride { host.trustedHostKey = trustedKeyOverride }
        let credentials = HostCredentials.load(for: host.id)

        feedLocal("\u{1b}[2mVerbinde mit \(host.endpoint) …\u{1b}[0m\r\n")

        task = Task { [weak self] in
            do {
                let client = try await SSHConnector.connect(to: host, credentials: credentials)
                guard let self else { try? await client.close(); return }
                self.client = client
                try await self.runShell(on: client)
                self.finish(.closed)
            } catch let error as SSHConnectError {
                guard let self else { return }
                switch error {
                case .unknownHostKey(let key, let fp):
                    self.state = .idle
                    self.hostKeyPrompt = HostKeyPrompt(key: key, fingerprint: fp, changed: false)
                case .hostKeyMismatch(let key, let fp):
                    self.state = .idle
                    self.hostKeyPrompt = HostKeyPrompt(key: key, fingerprint: fp, changed: true)
                default:
                    self.finish(.failed(error.localizedDescription))
                }
            } catch is CancellationError {
                self?.finish(.closed)
            } catch {
                self?.finish(.failed(SSHConnector.readable(error)))
            }
        }
    }

    func acceptHostKey(_ prompt: HostKeyPrompt) {
        hostKeyPrompt = nil
        onTrustHostKey?(prompt.key)
        start(trustedKeyOverride: prompt.key)
    }

    func rejectHostKey() {
        hostKeyPrompt = nil
        finish(.failed("Verbindung abgebrochen: Host-Schlüssel nicht vertraut."))
    }

    func disconnect() {
        task?.cancel()
        task = nil
        let client = self.client
        self.client = nil
        writer = nil
        Task { try? await client?.close() }
        if isActive { state = .closed }
    }

    private func finish(_ newState: State) {
        writer = nil
        let client = self.client
        self.client = nil
        Task { try? await client?.close() }
        state = newState
        switch newState {
        case .failed(let message):
            feedLocal("\r\n\u{1b}[31m✖ \(message)\u{1b}[0m\r\n")
        case .closed:
            feedLocal("\r\n\u{1b}[2m— Verbindung beendet —\u{1b}[0m\r\n")
        default: break
        }
    }

    private func runShell(on client: SSHClient) async throws {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        try await client.withPTY(request) { [weak self] inbound, outbound in
            guard let self else { return }
            self.writer = outbound
            self.state = .connected
            // Größe nachreichen, falls sich die View inzwischen gelayoutet hat.
            try? await outbound.changeSize(cols: self.cols, rows: self.rows, pixelWidth: 0, pixelHeight: 0)

            if let command = self.initialCommand, !command.isEmpty {
                try await outbound.write(ByteBuffer(string: command + "\n"))
            }

            for try await chunk in inbound {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    self.feed(Array(buffer.readableBytesView))
                }
            }
        }
    }

    // MARK: - I/O

    func send(_ bytes: [UInt8]) {
        guard let writer else { return }
        Task {
            try? await writer.write(ByteBuffer(bytes: bytes))
        }
    }

    func send(text: String) { send(Array(text.utf8)) }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        guard let writer else { return }
        Task {
            try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    private func feed(_ bytes: [UInt8]) {
        if let terminalView {
            terminalView.feed(byteArray: bytes[...])
        } else {
            pendingOutput.append(contentsOf: bytes)
        }
    }

    private func feedLocal(_ text: String) {
        feed(Array(text.utf8))
    }

    private func flushPending() {
        guard let terminalView, !pendingOutput.isEmpty else { return }
        terminalView.feed(byteArray: pendingOutput[...])
        pendingOutput.removeAll()
    }
}
