import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var catalog: CatalogService

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Katalog") {
                    Toggle("Dev-Scripts anzeigen", isOn: $settings.showDevScripts)
                    Toggle("Deaktivierte Scripts anzeigen", isOn: $settings.showDisabledScripts)
                    LabeledContent("Scripts", value: "\(catalog.scripts.count)")
                    if let date = catalog.lastUpdated {
                        LabeledContent("Aktualisiert", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button {
                        Task { await catalog.refresh() }
                    } label: {
                        HStack {
                            Label("Jetzt aktualisieren", systemImage: "arrow.clockwise")
                            Spacer()
                            if catalog.isLoading { ProgressView() }
                        }
                    }
                    .disabled(catalog.isLoading)
                }

                Section {
                    Stepper(value: $settings.terminalFontSize, in: 7...20, step: 0.5) {
                        LabeledContent("Schriftgröße", value: String(format: "%.1f pt", settings.terminalFontSize))
                    }
                    Toggle("Schrift an Breite anpassen", isOn: $settings.fitToWidth)
                    if settings.fitToWidth {
                        Stepper(value: $settings.minColumns, in: 60...160, step: 10) {
                            LabeledContent("Mindestens Spalten", value: "\(settings.minColumns)")
                        }
                    }
                    Text("root@pve:~# bash -c \"$(curl …)\"")
                        .font(.system(size: settings.terminalFontSize, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 6))
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Die Script-Menüs brauchen mindestens 60, besser 80 Spalten. Mit „An Breite anpassen“ wird die Schrift im Hochformat automatisch so weit verkleinert; die Schriftgröße oben ist dann die Obergrenze.")
                }

                Section("Tipps") {
                    Label("Im Terminal navigierst du Menüs mit den Pfeiltasten, wählst mit der Leertaste und bestätigst mit Enter – alles über die Tastenleiste.", systemImage: "keyboard")
                    Label("„Standard“-Modus installiert ohne Rückfragen mit den Werten des Scripts.", systemImage: "bolt")
                    Label("Für SSH-Schlüssel: öffentlichen Schlüssel in /root/.ssh/authorized_keys auf dem Host eintragen.", systemImage: "key")
                }
                .font(.callout)

                Section("Über") {
                    LabeledContent("Version", value: version)
                    Link(destination: URL(string: "https://community-scripts.org")!) {
                        Label("community-scripts.org", systemImage: "globe")
                    }
                    Link(destination: URL(string: "https://github.com/community-scripts/ProxmoxVE")!) {
                        Label("ProxmoxVE auf GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Text("Inoffizielle App. Die Scripts werden vom Community-Scripts-Projekt gepflegt (MIT-Lizenz) und laufen mit root-Rechten auf deinem Host.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
        }
    }
}
