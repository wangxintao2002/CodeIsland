import Foundation

struct RemoteTunnelStatus: Equatable {
    enum State: String {
        case disconnected
        case connecting
        case connected
        case failed
    }

    var state: State = .disconnected
    var lastError: String?
}

@MainActor
final class RemoteTunnelManager: ObservableObject {
    static let shared = RemoteTunnelManager()

    @Published private(set) var statuses: [String: RemoteTunnelStatus] = [:]

    private var processes: [String: Process] = [:]

    private init() {}

    func startConfiguredTunnels() {
        for profile in RemoteProfileStore.shared.allProfiles() where profile.enabled && profile.autoConnect {
            startTunnel(for: profile)
        }
    }

    func startTunnel(for profile: RemoteProfile) {
        guard profile.isValid else {
            statuses[profile.id] = RemoteTunnelStatus(state: .failed, lastError: "Invalid SSH alias or port")
            return
        }
        stopTunnel(profileId: profile.id)

        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            profile.sshHostAlias,
            "-R", "127.0.0.1:\(profile.remoteForwardPort):127.0.0.1:\(SettingsManager.shared.remoteLocalPort)"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.terminationHandler = { [weak self] proc in
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                self?.processes.removeValue(forKey: profile.id)
                let status: RemoteTunnelStatus.State = output?.isEmpty == false ? .failed : .disconnected
                self?.statuses[profile.id] = RemoteTunnelStatus(state: status, lastError: output)
            }
        }

        statuses[profile.id] = RemoteTunnelStatus(state: .connecting, lastError: nil)
        do {
            try process.run()
            processes[profile.id] = process
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self,
                      self.processes[profile.id]?.isRunning == true else { return }
                self.statuses[profile.id] = RemoteTunnelStatus(state: .connected, lastError: nil)
            }
        } catch {
            statuses[profile.id] = RemoteTunnelStatus(state: .failed, lastError: error.localizedDescription)
        }
    }

    func stopTunnel(profileId: String) {
        if let process = processes.removeValue(forKey: profileId) {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        statuses[profileId] = RemoteTunnelStatus(state: .disconnected, lastError: nil)
    }

    func stopAll() {
        for profileId in Array(processes.keys) {
            stopTunnel(profileId: profileId)
        }
    }

    func reconnect(profileId: String) {
        guard let profile = RemoteProfileStore.shared.profile(id: profileId) else { return }
        startTunnel(for: profile)
    }

    func status(for profileId: String) -> RemoteTunnelStatus {
        statuses[profileId] ?? RemoteTunnelStatus()
    }
}
