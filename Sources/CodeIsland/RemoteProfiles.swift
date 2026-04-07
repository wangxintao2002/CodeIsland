import Foundation

struct RemoteProfile: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String
    var sshHostAlias: String
    var remoteForwardPort: Int
    var autoConnect: Bool
    var enabled: Bool
    var jumpCommandTemplate: String

    init(
        id: String = UUID().uuidString,
        displayName: String = "New Remote",
        sshHostAlias: String = "",
        remoteForwardPort: Int = 39092,
        autoConnect: Bool = false,
        enabled: Bool = true,
        jumpCommandTemplate: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.sshHostAlias = sshHostAlias
        self.remoteForwardPort = remoteForwardPort
        self.autoConnect = autoConnect
        self.enabled = enabled
        self.jumpCommandTemplate = jumpCommandTemplate
    }

    var trimmedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? sshHostAlias : trimmed
    }

    var isValid: Bool {
        !sshHostAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && remoteForwardPort > 0
    }

    func tunnelCommand(localPort: Int) -> String {
        [
            "ssh",
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            sshHostAlias,
            "-R", "127.0.0.1:\(remoteForwardPort):127.0.0.1:\(localPort)"
        ].joined(separator: " ")
    }

    func environmentSnippet(localPort: Int) -> String {
        [
            "export CODEISLAND_HOST=127.0.0.1",
            "export CODEISLAND_PORT=\(remoteForwardPort)",
            "export CODEISLAND_REMOTE_PROFILE=\(id)",
            "export CODEISLAND_REMOTE_HOST_ALIAS=\(sshHostAlias)",
            "# Local CodeIsland listener: 127.0.0.1:\(localPort)"
        ].joined(separator: "\n")
    }
}

@MainActor
final class RemoteProfileStore: ObservableObject {
    static let shared = RemoteProfileStore()

    @Published var profiles: [RemoteProfile] = [] {
        didSet {
            guard !isLoading else { return }
            save()
        }
    }

    private let defaults = UserDefaults.standard
    private let profilesKey = "remoteProfiles"
    private var isLoading = false

    private init() {
        load()
    }

    func addProfile() {
        let nextPort = nextAvailablePort()
        profiles.append(RemoteProfile(remoteForwardPort: nextPort))
    }

    func update(_ profile: RemoteProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
    }

    func remove(profileId: String) {
        profiles.removeAll { $0.id == profileId }
    }

    func profile(id: String?) -> RemoteProfile? {
        guard let id else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    func allProfiles() -> [RemoteProfile] {
        profiles
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = defaults.data(forKey: profilesKey),
              let decoded = try? JSONDecoder().decode([RemoteProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
    }

    private func nextAvailablePort() -> Int {
        let used = Set(profiles.map(\.remoteForwardPort))
        var candidate = 39092
        while used.contains(candidate) {
            candidate += 1
        }
        return candidate
    }
}
