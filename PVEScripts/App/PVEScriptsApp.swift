import SwiftUI

@main
struct PVEScriptsApp: App {
    @StateObject private var catalog = CatalogService()
    @StateObject private var hosts = HostStore()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(catalog)
                .environmentObject(hosts)
                .environmentObject(settings)
                .tint(.accentColor)
        }
    }
}

/// Einstellungen, die per @AppStorage persistiert werden.
@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("showDevScripts") var showDevScripts = false
    @AppStorage("showDisabledScripts") var showDisabledScripts = false
    @AppStorage("terminalFontSize") var terminalFontSize: Double = 11
    @AppStorage("acceptedDisclaimer") var acceptedDisclaimer = false
}

struct RootView: View {
    @EnvironmentObject private var catalog: CatalogService
    @EnvironmentObject private var settings: AppSettings
    @State private var tab: Tab = .scripts

    enum Tab { case scripts, hosts, settings }

    var body: some View {
        TabView(selection: $tab) {
            ScriptsView()
                .tabItem { Label("Scripts", systemImage: "square.grid.2x2") }
                .tag(Tab.scripts)
            HostsView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
                .tag(Tab.hosts)
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .task { await catalog.refreshIfNeeded() }
        .sheet(isPresented: .constant(!settings.acceptedDisclaimer)) {
            DisclaimerView()
                .interactiveDismissDisabled()
        }
    }
}

struct DisclaimerView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                Text("Willkommen bei PVE Scripts")
                    .font(.largeTitle.bold())
                Text("Mit dieser App installierst du die [Proxmox VE Community Scripts](https://community-scripts.org) direkt vom iPhone oder iPad aus auf deinem Proxmox-Host.")
                VStack(alignment: .leading, spacing: 12) {
                    Label("Die App verbindet sich per SSH als root mit deinem Host und führt dort die Scripts aus.", systemImage: "lock.shield")
                    Label("Die Scripts stammen aus dem Community-Projekt und laufen mit vollen Rechten. Prüfe den Quellcode, bevor du etwas installierst.", systemImage: "exclamationmark.triangle")
                    Label("Zugangsdaten werden ausschließlich im Schlüsselbund deines Geräts gespeichert.", systemImage: "key")
                    Label("Diese App ist ein inoffizielles Projekt und steht in keiner Verbindung zu Proxmox Server Solutions oder community-scripts.", systemImage: "info.circle")
                }
                .font(.callout)
                Button {
                    settings.acceptedDisclaimer = true
                } label: {
                    Text("Verstanden")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .padding(24)
        }
    }
}
