import Foundation

enum AICommandPolicy {
    static let maxCommandBytes = 16_384
    private static let blocked: Set<String> = [
        "rm", "grm", "rmdir", "unlink", "shred", "srm", "trash", "dd", "diskutil", "fdisk",
        "newfs", "mkfs", "sudo", "su", "doas", "shutdown", "reboot", "halt", "launchctl",
        "kill", "killall", "pkill", "osascript", "eval", "source", ".", "alias", "unalias",
        "autoload", "function", "trap", "nohup", "disown", "setsid", "ssh", "scp", "sftp",
        "mv", "cp", "install", "tee", "truncate", "enable", "export", "unset", "set", "typeset",
        "declare", "read", "timeout", "gtimeout", "watch", "stdbuf", "vi", "vim", "nvim", "ex", "ed"
    ]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    static func refusal(_ command: String) -> String? {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "A command must not be empty."
        }
        guard command.utf8.count <= maxCommandBytes, !command.utf8.contains(0) else {
            return "The command is invalid or exceeds the size limit."
        }
        do {
            for words in try split(command) {
                if let reason = refusal(words, depth: 0) { return reason }
            }
            return nil
        } catch { return error.localizedDescription }
    }

    private static func refusal(_ words: [String], depth: Int) -> String? {
        guard depth < 8 else { return "Too many nested command wrappers." }
        var words = words
        while let word = words.first, assignment(word) {
            let key = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            if ["BASH_ENV", "ENV", "ZDOTDIR"].contains(key) || key.hasPrefix("DYLD_") || key.hasPrefix("LD_") {
                return "Shell startup and loader overrides are unavailable."
            }
            words.removeFirst()
        }
        guard let executable = words.first else { return nil }
        guard !executable.contains(where: { "$`*?[]{}()".contains($0) }) else {
            return "Use an explicit command name; dynamically chosen commands are unavailable."
        }
        let name = (executable as NSString).lastPathComponent.lowercased()
        let arguments = Array(words.dropFirst())
        if ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
            "select", "repeat", "coproc"].contains(name) {
            return "Shell control flow is unavailable. Run explicit commands or an existing project script."
        }
        if blocked.contains(name) || name.hasPrefix("mkfs.") || name.hasPrefix("newfs_") {
            return "\(name) is unavailable. Use the backed-up Files tools for edits, moves and Trash."
        }
        if ["env", "command", "exec", "builtin", "busybox", "toybox", "!", "time", "nice", "arch", "xcrun"].contains(name) {
            if name == "command", arguments.first == "-v" || arguments.first == "-V" { return nil }
            var wrapped = arguments
            if name == "arch", wrapped.first == "-arm64" || wrapped.first == "-x86_64" { wrapped.removeFirst() }
            if name == "nice", wrapped.first == "-n", wrapped.count >= 2 { wrapped.removeFirst(2) }
            if name == "time", wrapped.first == "-p" { wrapped.removeFirst() }
            if name == "xcrun" {
                while let first = wrapped.first, first.hasPrefix("-") {
                    if ["--find", "-f"].contains(first) { return nil }
                    if ["--sdk", "-sdk", "--toolchain", "-toolchain"].contains(first), wrapped.count >= 2 {
                        wrapped.removeFirst(2)
                    } else if ["--run", "-r", "--verbose", "-v", "--log", "-l"].contains(first) {
                        wrapped.removeFirst()
                    } else { return "This xcrun option is unavailable." }
                }
            }
            while wrapped.first == "--" || wrapped.first == "-i" { wrapped.removeFirst() }
            guard wrapped.first?.hasPrefix("-") != true else { return "This command wrapper option is unavailable." }
            return refusal(wrapped, depth: depth + 1)
        }
        if shells.contains(name), arguments.contains(where: { $0.hasPrefix("-") && $0.contains("c") }) {
            guard arguments.count == 2, ["-c", "-fc", "-cf"].contains(arguments[0]) else {
                return "Use a plain shell -c command without extra startup options or positional arguments."
            }
            do {
                for nested in try split(arguments[1]) {
                    if let reason = refusal(nested, depth: depth + 1) { return reason }
                }
            } catch { return error.localizedDescription }
            return nil
        }
        if shells.contains(name), !arguments.contains("-c") {
            guard let first = arguments.first, !first.hasPrefix("-"),
                !arguments.contains(where: { $0.contains("$") }) else {
                return "Run an explicit project script or a checked shell -c command."
            }
        }
        let inlineFlags: [String]
        if name.hasPrefix("python") {
            inlineFlags = ["-c"]
        } else if name == "node" {
            inlineFlags = ["-e", "-p", "--eval", "--print"]
        } else if ["ruby", "perl", "swift", "lua", "luajit", "julia", "elixir", "rscript"].contains(name) {
            inlineFlags = ["-e"]
        } else if name == "php" {
            inlineFlags = ["-r"]
        } else if ["powershell", "pwsh"].contains(name) {
            inlineFlags = ["-command", "-encodedcommand", "-c"]
        } else { inlineFlags = [] }
        if arguments.contains(where: { argument in inlineFlags.contains { argument.lowercased().hasPrefix($0) } })
            || (name == "perl" && arguments.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("e") }))
            || (["awk", "gawk", "mawk", "nawk"].contains(name) && !arguments.contains(where: { $0.hasPrefix("-f") })) {
            return "Inline interpreter programs are unavailable. Run a project's build or test script instead."
        }
        if ["sed", "gsed"].contains(name), arguments.contains(where: { $0.hasPrefix("-i") }) {
            return "In-place shell edits are unavailable. Use edit_file to preserve the original."
        }
        if name == "find", arguments.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
            return "find may search files, but cannot execute commands or delete them."
        }
        if name == "xargs" { return "Invoke the command directly so its operation can be checked." }
        if name == "git" { return gitRefusal(arguments) }
        if name == "rsync", arguments.contains(where: { $0.hasPrefix("--delete") }) {
            return "Deleting files through rsync is unavailable."
        }
        return nil
    }

    private static func gitRefusal(_ arguments: [String]) -> String? {
        var arguments = arguments
        while let first = arguments.first, first.hasPrefix("-") {
            arguments.removeFirst()
            if ["-C", "-c", "--git-dir", "--work-tree"].contains(first), !arguments.isEmpty { arguments.removeFirst() }
        }
        let verb = arguments.first ?? ""
        let rest = Array(arguments.dropFirst())
        let destructive: Set<String> = ["reset", "clean", "restore", "checkout", "prune", "gc", "filter-branch", "filter-repo"]
        if destructive.contains(verb)
            || rest.contains(where: { ["--force", "-f", "-D", "--discard-changes", "--delete"].contains($0) })
            || rest.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("f") })
            || (verb == "push" && rest.contains(where: { $0.hasPrefix("--force") || $0.hasPrefix("+") || $0.hasPrefix(":") }))
            || (verb == "stash" && rest.contains(where: { ["drop", "clear"].contains($0) }))
            || (["branch", "tag"].contains(verb) && rest.contains("-d")) {
            return "This Git command may discard work or delete history. Use non-destructive Git commands."
        }
        if verb == "push", rest.contains("-d") { return "Deleting remote Git branches is unavailable." }
        let allowed: Set<String> = ["status", "diff", "log", "show", "ls-files", "ls-tree", "rev-parse", "describe",
                                   "blame", "grep", "branch", "tag", "fetch", "add", "commit", "push", "switch", "stash"]
        guard verb.isEmpty || allowed.contains(verb) else {
            return "This Git operation is unavailable through automatic command execution."
        }
        return nil
    }

    private static func assignment(_ word: String) -> Bool {
        guard let separator = word.firstIndex(of: "="), separator != word.startIndex else { return false }
        let key = word[..<separator]
        return key.first?.isNumber != true && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func split(_ command: String) throws -> [[String]] {
        let characters = Array(command)
        var index = 0
        var quote: Character?
        var token = ""
        var started = false
        var words: [String] = []
        var commands: [[String]] = []
        func finishWord() {
            if started { words.append(token); token = ""; started = false }
        }
        func finishCommand() {
            finishWord()
            if !words.isEmpty { commands.append(words); words = [] }
        }
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "\\", quote != "'" {
                guard let next else { throw Failure("An incomplete escape is unavailable.") }
                if next != "\n" { token.append(next); started = true }
                index += 2; continue
            }
            if character == "`" || (character == "$" && next == "("), quote != "'" {
                throw Failure("Command substitution is unavailable. Run its commands separately.")
            }
            if let active = quote {
                if character == active { quote = nil } else { token.append(character) }
                index += 1; continue
            }
            if character == "'" || character == "\"" { quote = character; started = true } else if character == "#", !started {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            } else if character == "<" || character == ">" {
                throw Failure("Shell redirection is unavailable. Use Files for edits; output is captured automatically.")
            } else if "(){}".contains(character) {
                throw Failure("Shell definitions and subshells are unavailable. Use explicit commands.")
            } else if character == "&" {
                guard next == "&" else { throw Failure("Background commands are unavailable.") }
                finishCommand(); index += 2; continue
            } else if character == ";" || character == "|" || character == "\n" {
                finishCommand()
                if character == "|", next == "|" { index += 1 }
            } else if character.isWhitespace { finishWord() } else { token.append(character); started = true }
            index += 1
        }
        guard quote == nil else { throw Failure("A quoted command is incomplete.") }
        finishCommand()
        return commands
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
