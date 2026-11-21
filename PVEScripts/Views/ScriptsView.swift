import SwiftUI

struct ScriptsView: View {
    @EnvironmentObject private var catalog: CatalogService
    @EnvironmentObject private var settings: AppSettings

    @State private var searchText = ""
    @State private var selectedCategory: String?
    @State private var selectedType: ScriptType?
    @State private var sort: SortOrder = .name

    enum SortOrder: String, CaseIterable, Identifiable {
        case name, updated
        var id: String { rawValue }
        var title: String { self == .name ? "Name" : "Zuletzt aktualisiert" }
    }

    private var filtered: [Script] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var list = catalog.scripts.filter { script in
            if !settings.showDevScripts && script.isDev { return false }
            if !settings.showDisabledScripts && script.isDisabled { return false }
            if let selectedType, script.type != selectedType { return false }
            if let selectedCategory, !script.categoryIDs.contains(selectedCategory) { return false }
            if query.isEmpty { return true }
            return script.name.localizedCaseInsensitiveContains(query)
                || script.slug.localizedCaseInsensitiveContains(query)
                || script.description.localizedCaseInsensitiveContains(query)
        }
        if sort == .updated {
            list.sort { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        }
        if !query.isEmpty {
            // Treffer im Namen zuerst.
            list.sort { a, b in
                let aHit = a.name.localizedCaseInsensitiveContains(query)
                let bHit = b.name.localizedCaseInsensitiveContains(query)
                return aHit && !bHit
            }
        }
        return list
    }

    private var visibleCategories: [ScriptCategory] {
        let used = Set(catalog.scripts.flatMap(\.categoryIDs))
        return catalog.categories.filter { used.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = catalog.lastError {
                    Section {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                Section {
                    ForEach(filtered) { script in
                        NavigationLink(value: script) {
                            ScriptRow(script: script)
                        }
                    }
                } header: {
                    if !catalog.scripts.isEmpty {
                        Text("\(filtered.count) Scripts")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if catalog.scripts.isEmpty {
                    if catalog.isLoading {
                        ProgressView("Katalog wird geladen …")
                    } else {
                        ContentUnavailableView {
                            Label("Keine Scripts", systemImage: "tray")
                        } description: {
                            Text(catalog.lastError ?? "Der Katalog konnte nicht geladen werden.")
                        } actions: {
                            Button("Erneut versuchen") { Task { await catalog.refresh() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !visibleCategories.isEmpty {
                    CategoryBar(categories: visibleCategories, selection: $selectedCategory)
                }
            }
            .navigationTitle("Community Scripts")
            .navigationDestination(for: Script.self) { script in
                ScriptDetailView(script: script)
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Suchen, z. B. Home Assistant")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .refreshable { await catalog.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Typ", selection: $selectedType) {
                            Text("Alle Typen").tag(ScriptType?.none)
                            ForEach(ScriptType.allCases.filter { $0 != .unknown }) { type in
                                Label(type.title, systemImage: type.symbol).tag(ScriptType?.some(type))
                            }
                        }
                        Picker("Sortierung", selection: $sort) {
                            ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
                        }
                        Divider()
                        Toggle("Dev-Scripts anzeigen", isOn: $settings.showDevScripts)
                    } label: {
                        Image(systemName: selectedType == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                if catalog.isLoading && !catalog.scripts.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { ProgressView() }
                }
            }
        }
    }
}

private struct CategoryBar: View {
    let categories: [ScriptCategory]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Alle", symbol: "square.grid.2x2", selected: selection == nil) {
                    selection = nil
                }
                ForEach(categories) { category in
                    chip(title: category.name, symbol: category.symbol, selected: selection == category.id) {
                        selection = selection == category.id ? nil : category.id
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func chip(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct ScriptRow: View {
    let script: Script

    var body: some View {
        HStack(spacing: 12) {
            ScriptLogo(url: script.logoURL, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(script.name)
                        .font(.headline)
                        .lineLimit(1)
                    TypeBadge(type: script.type)
                    if script.isDev { Badge(text: "DEV", color: .purple) }
                    if script.isDisabled { Badge(text: "AUS", color: .red) }
                }
                Text(script.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ScriptLogo: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.15))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Image(systemName: "shippingbox")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .padding(size * 0.12)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

struct TypeBadge: View {
    let type: ScriptType
    var body: some View {
        Badge(text: type.title, color: color)
    }
    private var color: Color {
        switch type {
        case .lxc: .blue
        case .vm: .indigo
        case .addon: .teal
        case .pve: .orange
        case .turnkey: .green
        case .unknown: .gray
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
