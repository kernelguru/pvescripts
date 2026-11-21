import Foundation

/// Lädt den Script-Katalog aus der öffentlichen PocketBase-API, die auch
/// community-scripts.org verwendet, und cached ihn lokal für den Offline-Betrieb.
@MainActor
final class CatalogService: ObservableObject {
    static let apiBase = URL(string: "https://db.community-scripts.org/api/collections")!

    @Published private(set) var scripts: [Script] = []
    @Published private(set) var categories: [ScriptCategory] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?

    private let session: URLSession
    private let cacheURL: URL

    init(session: URLSession = .shared) {
        self.session = session
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = dir.appendingPathComponent("catalog-v1.json")
        loadCache()
    }

    func category(for id: String) -> ScriptCategory? {
        categories.first { $0.id == id }
    }

    func refreshIfNeeded() async {
        let stale = lastUpdated.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        if scripts.isEmpty || stale { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            async let cats = fetchCategories()
            async let all = fetchScripts()
            let (c, s) = try await (cats, all)
            categories = c.sorted { $0.sortOrder < $1.sortOrder }
            scripts = s.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            lastUpdated = Date()
            saveCache()
        } catch is CancellationError {
            // Pull-to-refresh abgebrochen – nichts tun.
        } catch let error as URLError where error.code == .cancelled {
            // dito
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
        lastUpdated = nil
    }

    // MARK: - Networking

    private func fetchCategories() async throws -> [ScriptCategory] {
        let page: PBPage<PBCategory> = try await get("script_categories/records", query: [
            "perPage": "500",
            "fields": "id,name,icon,sort_order",
        ])
        return page.items.map { ScriptCategory(id: $0.id, name: $0.name, icon: $0.icon, sortOrder: $0.sort_order ?? 999) }
    }

    private func fetchScripts() async throws -> [Script] {
        var result: [Script] = []
        var page = 1
        var totalPages = 1
        repeat {
            let response: PBPage<PBScript> = try await get("script_scripts/records", query: [
                "page": String(page),
                "perPage": "500",
                "filter": "is_deleted=false",
                "expand": "type",
                "fields": [
                    "id", "slug", "name", "description", "logo", "port", "website", "documentation",
                    "is_dev", "is_disabled", "disable_message", "updateable", "privileged",
                    "default_user", "default_passwd", "install_methods", "notes", "categories",
                    "execute_in", "script_updated", "has_arm", "expand.type.type",
                ].joined(separator: ","),
            ])
            result += response.items.map { $0.toScript() }
            totalPages = max(response.totalPages, 1)
            page += 1
        } while page <= totalPages && page < 20
        return result
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var components = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Cache

    private struct CacheFile: Codable {
        var date: Date
        var scripts: [Script]
        var categories: [ScriptCategory]
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        scripts = cache.scripts
        categories = cache.categories
        lastUpdated = cache.date
    }

    private func saveCache() {
        let cache = CacheFile(date: lastUpdated ?? Date(), scripts: scripts, categories: categories)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

enum CatalogError: LocalizedError {
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .http(let code): "Der Katalog-Server antwortete mit HTTP \(code)."
        }
    }
}

// MARK: - PocketBase DTOs

private struct PBPage<Item: Decodable>: Decodable {
    var page: Int
    var totalPages: Int
    var items: [Item]
}

private struct PBCategory: Decodable {
    var id: String
    var name: String
    var icon: String?
    var sort_order: Int?
}

private struct PBScript: Decodable {
    struct Expand: Decodable {
        struct TypeRef: Decodable { var type: String? }
        var type: TypeRef?
    }

    var id: String
    var slug: String
    var name: String
    var description: String?
    var logo: String?
    var port: Int?
    var website: String?
    var documentation: String?
    var isDev: Bool?
    var isDisabled: Bool?
    var disableMessage: String?
    var updateable: Bool?
    var privileged: Bool?
    var defaultUser: String?
    var defaultPassword: String?
    var installMethods: [InstallMethod]
    var notes: [ScriptNote]
    var categories: [String]
    var executeIn: [String]
    var scriptUpdated: String?
    var hasArm: Bool?
    var expand: Expand?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, logo, port, website, documentation, updateable, privileged, notes, categories, expand
        case isDev = "is_dev"
        case isDisabled = "is_disabled"
        case disableMessage = "disable_message"
        case defaultUser = "default_user"
        case defaultPassword = "default_passwd"
        case installMethods = "install_methods"
        case executeIn = "execute_in"
        case scriptUpdated = "script_updated"
        case hasArm = "has_arm"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        name = c.lossyString(.name) ?? slug
        description = c.lossyString(.description)
        logo = c.lossyString(.logo)
        port = c.lossyInt(.port)
        website = c.lossyString(.website)
        documentation = c.lossyString(.documentation)
        isDev = c.lossyBool(.isDev)
        isDisabled = c.lossyBool(.isDisabled)
        disableMessage = c.lossyString(.disableMessage)
        updateable = c.lossyBool(.updateable)
        privileged = c.lossyBool(.privileged)
        defaultUser = c.lossyString(.defaultUser)
        defaultPassword = c.lossyString(.defaultPassword)
        installMethods = (try? c.decodeIfPresent([InstallMethod].self, forKey: .installMethods)) ?? []
        notes = (try? c.decodeIfPresent([ScriptNote].self, forKey: .notes)) ?? []
        categories = (try? c.decodeIfPresent([String].self, forKey: .categories)) ?? []
        executeIn = (try? c.decodeIfPresent([String].self, forKey: .executeIn)) ?? []
        scriptUpdated = c.lossyString(.scriptUpdated)
        hasArm = c.lossyBool(.hasArm)
        expand = try? c.decodeIfPresent(Expand.self, forKey: .expand)
    }

    func toScript() -> Script {
        Script(
            id: id,
            slug: slug,
            name: name,
            description: description ?? "",
            logo: logo?.isEmpty == true ? nil : logo,
            port: (port ?? 0) > 0 ? port : nil,
            website: website,
            documentation: documentation,
            isDev: isDev ?? false,
            isDisabled: isDisabled ?? false,
            disableMessage: disableMessage,
            updateable: updateable ?? false,
            privileged: privileged ?? false,
            defaultUser: defaultUser?.isEmpty == true ? nil : defaultUser,
            defaultPassword: defaultPassword?.isEmpty == true ? nil : defaultPassword,
            installMethods: installMethods,
            notes: notes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty },
            categoryIDs: categories,
            type: ScriptType(rawValue: expand?.type?.type?.lowercased() ?? "") ?? .unknown,
            executeIn: executeIn,
            updatedAt: scriptUpdated,
            hasArm: hasArm ?? false
        )
    }
}
