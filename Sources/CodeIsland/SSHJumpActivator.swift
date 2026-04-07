import Foundation
import CodeIslandCore

enum SSHJumpActivator {
    @MainActor
    static func activate(session: SessionSnapshot) {
        guard session.isRemote,
              let host = session.remoteHostAlias ?? session.originDisplayName,
              !host.isEmpty else { return }

        let command: String
        if let template = RemoteProfileStore.shared.profile(id: session.remoteProfileId)?.jumpCommandTemplate,
           !template.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            command = template
                .replacingOccurrences(of: "{host}", with: host)
                .replacingOccurrences(of: "{cwd}", with: session.cwd ?? "")
        } else {
            let escapedCwd = shellSingleQuoted(session.cwd ?? "~")
            command = "ssh -t \(host) 'cd \(escapedCwd) && exec $SHELL -l'"
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        do {
            try proc.run()
        } catch {
            return
        }
    }

    private static func shellSingleQuoted(_ input: String) -> String {
        "'\(input.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
