import Foundation

enum AIFileAccessPolicy {
    static func refusal(path: String, home: String, revisions: String, moving: Bool) -> String? {
        if contains(path, revisions) || contains(revisions, path) {
            return "Oz's file checkpoints and their parent directories are protected."
        }
        if path.split(separator: "/").contains(where: { $0 == ".git" || $0 == ".codex" }) {
            return "Git metadata and Codex configuration are protected. Edit project files instead."
        }
        let system = ["/System", "/usr", "/bin", "/sbin", "/dev", "/Library",
                      "/private/etc", "/private/var/db"]
        if system.contains(where: { contains($0, path) }) {
            return "Changing this system path is blocked."
        }
        guard moving else { return nil }
        if system.contains(where: { contains(path, $0) }) {
            return "Moving or trashing a parent of protected system files is blocked."
        }
        let roots = ["/", home, "/Users", "/Volumes", "/System", "/Library", "/usr", "/bin", "/sbin",
                     "/private", "/dev", home + "/Desktop", home + "/Documents", home + "/Downloads",
                     home + "/Library", home + "/Pictures", home + "/Music", home + "/Movies"]
        if roots.contains(path) {
            return "Moving or trashing this system or home directory is blocked."
        }
        return nil
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }
}
