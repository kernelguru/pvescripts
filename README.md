# PVE Scripts – iOS-App für die Proxmox VE Community Scripts

Native SwiftUI-App für iPhone und iPad, mit der du die
[Proxmox VE Community Scripts](https://community-scripts.org) durchsuchen und
direkt per SSH auf deinem Proxmox-Host installieren kannst.

## Funktionen

- **Katalog** mit allen ~870 Scripts (LXC, VM, Add-ons, PVE-Tools), live aus der
  öffentlichen API von community-scripts.org, offline gecacht
- Suche, Kategorien-Leiste, Filter nach Typ, Dev-Scripts optional
- **Detailseite** mit Standard-Ressourcen, Zugangsdaten, Hinweisen, Links zum Quellcode
  und dem Install-Befehl zum Kopieren
- **Installation per SSH** in einem echten Terminal (xterm-256color via SwiftTerm),
  damit auch die Whiptail-Menüs der Scripts funktionieren
  - Modus *Menü* (wie im Proxmox-Shell), *Standard* (ohne Rückfragen, `mode=default`)
    oder *Erweitert* (`mode=advanced`)
  - Overrides für CPU, RAM, Disk, Hostname, CT-ID, (un)privilegiert, verbose
  - Alpine-Variante, wenn das Script sie anbietet
  - Add-ons, die in einem bestehenden LXC laufen, werden per `pct exec` im
    ausgewählten Container ausgeführt
- **Mobile Tastenleiste** für Whiptail: Pfeile, Tab, Leertaste, Enter, Esc, Strg-C,
  Einfügen – auch ohne eingeblendete Tastatur
- **Hosts**: mehrere Proxmox-Hosts, Passwort oder SSH-Schlüssel (Ed25519/RSA,
  OpenSSH-Format, optional mit Passphrase), Trust-On-First-Use für Host-Schlüssel mit
  SHA256-Fingerprint, Zugangsdaten nur im iOS-Schlüsselbund
- **Proxmox-Admin** (über `pvesh` per SSH – kein API-Token nötig, clusterweit):
  - Dashboard pro Node: CPU, RAM, Root-Disk, Swap, Load, Version, Storage-Belegung,
    automatische Aktualisierung
  - Gäste-Liste mit Filter/Suche, Live-Auslastung, Start/Stopp per Wischgeste
  - Detailansicht: Starten, Herunterfahren, Neustarten, Pausieren/Fortsetzen, hart Stoppen,
    Live-Ressourcen (CPU, RAM, Disk, Netz, I/O), **IP-Adressen** (QEMU-Agent bzw. LXC)
  - **Konsolen**: serielle Konsole (`qm terminal`), LXC-Konsole/Root-Shell, **noVNC**
    über die Weboberfläche mit automatischer Anmeldung
  - **Neue VMs/Container**: ISO bzw. Vorlage wählen, ISO per URL laden,
    LXC-Vorlagen herunterladen, CPU/RAM/Disk/Netz, UEFI/TPM für Windows 11
  - **Bearbeiten inkl. Hardware**: CPU, RAM, Ballooning, Disks hinzufügen/vergrößern/
    aushängen, Netzwerkkarten, CD/DVD, Optionen (Autostart, Schutz, Tags, Notizen,
    Nesting) und Experten-Editor für alle Config-Schlüssel
  - Snapshots (inkl. RAM), Backup jetzt, Klonen, Löschen, Task-Liste mit Live-Log
  - **QEMU-Gast-Agent**: aktivieren, VM aus/ein schalten, per SSH im Gast installieren
    (apt/dnf/yum/zypper/apk/pacman) oder Befehle kopieren; Hinweis für Windows
  - Host-Shell und `apt dist-upgrade`, Community-Script-`update` in Containern

## Projektstruktur

```
project.yml                 XcodeGen-Spezifikation (das .xcodeproj wird generiert)
PVEScripts/
  App/                      App-Einstieg, Tabs, Einstellungen
  Models/                   Script-, Kategorie- und Host-Modelle
  Services/                 Katalog-API, Befehlsaufbau, SSH (Citadel), Terminal-Session
  Views/                    SwiftUI-Oberfläche inkl. Terminal (SwiftTerm)
  Resources/Assets.xcassets App-Icon, Akzentfarbe
.github/workflows/build-ipa.yml   GitHub-Actions-Build der IPA
```

Abhängigkeiten (Swift Package Manager):
[Citadel](https://github.com/orlandos-nl/Citadel) (SSH) und
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (Terminal-Emulator).

## IPA mit GitHub Actions bauen

Der Workflow `.github/workflows/build-ipa.yml` läuft auf einem macOS-Runner bei jedem
Push, bei Pull Requests, manuell (*Actions → Build iOS IPA → Run workflow*) und bei Tags
`v*`.

1. Er generiert das Xcode-Projekt mit XcodeGen und baut ein Release-Archiv.
2. Immer entsteht eine **unsignierte IPA** (`…-unsigned.ipa`) als Build-Artefakt.
3. Wenn Signing-Secrets hinterlegt sind, entsteht zusätzlich eine **signierte IPA**.
4. Bei einem Tag wie `v1.0.0` wird ein GitHub-Release mit den IPAs erstellt.

Die IPA findest du im Workflow-Lauf unter *Artifacts*.

### Unsignierte IPA installieren

Die unsignierte IPA kannst du mit einem Sideloading-Tool installieren, das sie selbst
mit deiner Apple-ID signiert, z. B. **AltStore / SideStore**, **Sideloadly** oder – auf
unterstützten iOS-Versionen – **TrollStore**. Mit einer kostenlosen Apple-ID läuft die
App 7 Tage und muss dann neu signiert werden.

### Signierte IPA (optional)

Unter *Settings → Secrets and variables → Actions* anlegen:

| Secret | Inhalt |
| --- | --- |
| `IOS_CERTIFICATE_P12_BASE64` | Signing-Zertifikat (`.p12`, Development oder Distribution), base64: `base64 -i cert.p12 \| pbcopy` |
| `IOS_CERTIFICATE_PASSWORD` | Passwort der `.p12` |
| `IOS_PROVISIONING_PROFILE_BASE64` | Passendes Provisioning-Profil (Development oder Ad Hoc mit deinen Geräte-UDIDs), base64 |

Optional als *Variable* `BUNDLE_ID` die Bundle-ID setzen (Standard:
`com.kernelguru.pvescripts`). Bei einem Profil mit fester App-ID wird dessen Bundle-ID
übernommen, bei einem Wildcard-Profil die `BUNDLE_ID`.

Die signierte IPA kannst du z. B. über den Finder/Apple Configurator oder einen
OTA-Link auf registrierten Geräten installieren.

## Lokal bauen (Mac)

```bash
brew install xcodegen
xcodegen generate
open PVEScripts.xcodeproj
```

Dann in Xcode dein Team unter *Signing & Capabilities* auswählen und auf dem Gerät
starten. Voraussetzung: Xcode 16 oder neuer, iOS 17+.

## Proxmox vorbereiten

- SSH muss für `root` erreichbar sein (Standard bei Proxmox VE).
- Für Schlüssel-Login den öffentlichen Schlüssel in `/root/.ssh/authorized_keys`
  eintragen. Private Schlüssel müssen im OpenSSH-Format vorliegen
  (`-----BEGIN OPENSSH PRIVATE KEY-----`), z. B. erzeugt mit `ssh-keygen -t ed25519`.
- Beim ersten Verbinden zeigt die App den Host-Fingerprint. Vergleichen mit:
  `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`

## Hinweise

- noVNC nutzt die Weboberfläche auf Port 8006. Bei selbst signiertem Zertifikat
  akzeptiert die App das Zertifikat nur für den eingetragenen Host. Bleibt die Konsole
  schwarz, blockiert iOS ggf. die WebSocket-Verbindung – dann ein gültiges Zertifikat
  (z. B. ACME/Let's Encrypt in Proxmox) einrichten oder die serielle Konsole nutzen.

- Die Scripts laufen mit root-Rechten auf deinem Host. Lies den Quellcode
  (Link auf jeder Detailseite), bevor du etwas installierst.
- Wird die SSH-Verbindung während einer Installation getrennt (z. B. wenn die App in den
  Hintergrund geht), bricht das Script ab. Lass die App während der Installation offen –
  die automatische Display-Sperre ist im Terminal deaktiviert.
- Whiptail-Menüs brauchen etwa 80 Spalten – im Querformat oder mit kleinerer Schrift
  (Einstellungen) werden sie vollständig angezeigt.
- Dies ist ein inoffizielles Projekt ohne Verbindung zu Proxmox Server Solutions GmbH
  oder dem community-scripts-Projekt.
