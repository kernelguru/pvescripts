import Foundation
import CryptoKit
import Citadel
import NIOCore
import NIOSSH

/// Fehler, die beim Verbindungsaufbau dem Nutzer verständlich gemacht werden.
enum SSHConnectError: LocalizedError {
    case missingAddress
    case missingCredentials
    case unsupportedKey(String)
    case invalidKey(String)
    /// Host-Schlüssel ist noch unbekannt – Nutzer muss ihm vertrauen.
    case unknownHostKey(key: String, fingerprint: String)
    /// Host-Schlüssel hat sich geändert – möglicher MITM-Angriff oder Neuinstallation.
    case hostKeyMismatch(key: String, fingerprint: String)
    case authenticationFailed
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .missingAddress: "Für diesen Host ist keine Adresse hinterlegt."
        case .missingCredentials: "Für diesen Host sind keine Zugangsdaten hinterlegt."
        case .unsupportedKey(let type): "Schlüsseltyp \(type) wird nicht unterstützt. Bitte Ed25519 oder RSA im OpenSSH-Format verwenden."
        case .invalidKey(let reason): "Der private Schlüssel konnte nicht gelesen werden: \(reason)"
        case .unknownHostKey(_, let fp): "Unbekannter Host-Schlüssel\n\(fp)"
        case .hostKeyMismatch(_, let fp): "ACHTUNG: Der Host-Schlüssel hat sich geändert!\n\(fp)"
        case .authenticationFailed: "Anmeldung fehlgeschlagen. Benutzername, Passwort oder Schlüssel prüfen."
        case .underlying(let message): message
        }
    }
}

struct HostKeyRejected: Error {}

/// Trust-On-First-Use-Prüfung des Host-Schlüssels.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    enum Outcome { case pending, trusted, unknown(String), mismatch(String) }

    private let expected: String?
    private let lock = NSLock()
    private var _outcome: Outcome = .pending

    var outcome: Outcome { lock.withLock { _outcome } }

    init(expected: String?) {
        self.expected = expected.map(Self.normalize)
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = Self.normalize(String(openSSHPublicKey: hostKey))
        if let expected {
            if expected == presented {
                lock.withLock { _outcome = .trusted }
                validationCompletePromise.succeed(())
            } else {
                lock.withLock { _outcome = .mismatch(presented) }
                validationCompletePromise.fail(HostKeyRejected())
            }
        } else {
            lock.withLock { _outcome = .unknown(presented) }
            validationCompletePromise.fail(HostKeyRejected())
        }
    }

    /// Nur "typ base64" behalten, Kommentar entfernen.
    static func normalize(_ key: String) -> String {
        key.split(separator: " ").prefix(2).joined(separator: " ")
    }

    /// SHA256-Fingerprint wie bei `ssh-keygen -lf`.
    static func fingerprint(of key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return key }
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "\(parts[0]) SHA256:\(b64)"
    }
}

enum SSHConnector {
    static func connect(to host: ProxmoxHost, credentials: HostCredentials) async throws -> SSHClient {
        let address = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw SSHConnectError.missingAddress }

        let auth = try authenticationMethod(for: host, credentials: credentials)
        let validator = TOFUHostKeyValidator(expected: host.trustedHostKey)

        do {
            return try await SSHClient.connect(
                host: address,
                port: host.port,
                authenticationMethod: auth,
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: .seconds(15)
            )
        } catch {
            switch validator.outcome {
            case .unknown(let key):
                throw SSHConnectError.unknownHostKey(key: key, fingerprint: TOFUHostKeyValidator.fingerprint(of: key))
            case .mismatch(let key):
                throw SSHConnectError.hostKeyMismatch(key: key, fingerprint: TOFUHostKeyValidator.fingerprint(of: key))
            case .pending, .trusted:
                if error is AuthenticationFailed {
                    throw SSHConnectError.authenticationFailed
                }
                let text = String(describing: error)
                if text.localizedCaseInsensitiveContains("auth") {
                    throw SSHConnectError.authenticationFailed
                }
                throw SSHConnectError.underlying(readable(error))
            }
        }
    }

    static func authenticationMethod(for host: ProxmoxHost, credentials: HostCredentials) throws -> SSHAuthenticationMethod {
        let user = host.username.isEmpty ? "root" : host.username
        switch host.authMethod {
        case .password:
            guard !credentials.password.isEmpty else { throw SSHConnectError.missingCredentials }
            return .passwordBased(username: user, password: credentials.password)
        case .privateKey:
            let key = credentials.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw SSHConnectError.missingCredentials }
            let passphrase = credentials.passphrase.isEmpty ? nil : Data(credentials.passphrase.utf8)
            let type: SSHKeyType
            do {
                type = try SSHKeyDetection.detectPrivateKeyType(from: key)
            } catch {
                throw SSHConnectError.invalidKey("Nur Schlüssel im Format „-----BEGIN OPENSSH PRIVATE KEY-----“ werden unterstützt.")
            }
            do {
                if type == .ed25519 {
                    let pk = try Curve25519.Signing.PrivateKey(sshEd25519: key, decryptionKey: passphrase)
                    return .ed25519(username: user, privateKey: pk)
                } else if type == .rsa {
                    let pk = try Insecure.RSA.PrivateKey(sshRsa: key, decryptionKey: passphrase)
                    return .rsa(username: user, privateKey: pk)
                } else {
                    throw SSHConnectError.unsupportedKey(type.description)
                }
            } catch let error as SSHConnectError {
                throw error
            } catch {
                throw SSHConnectError.invalidKey(passphrase == nil ? "Ist der Schlüssel passwortgeschützt?" : "Passphrase falsch?")
            }
        }
    }

    static func readable(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        let ns = error as NSError
        if ns.domain != "Foundation._GenericObjCError" && !ns.localizedDescription.isEmpty
            && !ns.localizedDescription.contains("operation couldn’t be completed") {
            return ns.localizedDescription
        }
        let text = String(describing: error)
        if text.contains("connectTimeout") || text.contains("timeout") {
            return "Zeitüberschreitung – ist der Host erreichbar?"
        }
        if text.contains("connectionRefused") || text.contains("Connection refused") {
            return "Verbindung abgelehnt – läuft SSH auf dem Port?"
        }
        return "Verbindung fehlgeschlagen: \(text)"
    }
}
