import CryptoKit
import Darwin
import Foundation

struct AIFileToolRunner: Sendable {
    let home: URL
    let revisions: URL
    static let maxFileBytes = 8 * 1_048_576
    private static let maxOutputBytes = 24_576

    func invoke(_ call: AIToolCall) async -> AIToolResult {
        let task = Task.detached { execute(call) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func execute(_ call: AIToolCall) -> AIToolResult {
        do {
            try Task.checkCancellation()
            guard call.arguments.utf8.count <= Self.maxFileBytes * 2 else {
                throw Failure("Filesystem arguments exceed the size limit.")
            }
            guard AIFileTools.owns(call.name),
                let arguments = JSONValue(data: Data(call.arguments.utf8))?.objectValue
            else { throw Failure("Unknown filesystem tool or invalid arguments.") }
            let name = String(call.name.dropFirst(AIFileTools.prefix.count))
            let result: [String: Any]
            switch name {
            case "list_directory": result = try list(arguments)
            case "find_files", "search_files": result = try search(arguments, contents: name == "search_files")
            case "read_file": result = try read(arguments)
            case "file_versions": result = try versions(arguments)
            case "run_command":
                let directory = try path(arguments, key: "working_directory")
                try requireDirectory(directory)
                let timeout = integer(arguments, "timeout_seconds", default: 120, maximum: 900)
                result = try AICommandRunner(home: home, environment: ProcessInfo.processInfo.environment)
                    .run(try string(arguments, "command"), directory: directory, timeout: TimeInterval(timeout))
            default: result = try withMutationLock { try mutate(name, arguments) }
            }
            let data = try boundedResult(result)
            let failed = name == "run_command" && ((result["exit_code"] as? Int) != 0 || result["timed_out"] as? Bool == true)
            return AIToolResult(callID: call.id, content: String(data: data, encoding: .utf8) ?? "{}", isError: failed)
        } catch {
            return .failure(call.id, error.localizedDescription)
        }
    }

    private func path(
        _ arguments: [String: JSONValue], key: String = "path", moving: Bool = false
    ) throws -> URL {
        let raw = try string(arguments, key)
        let expanded = raw == "~" ? home.path : raw.hasPrefix("~/") ? home.path + raw.dropFirst() : raw
        guard expanded.hasPrefix("/"), !expanded.utf8.contains(0) else {
            throw Failure("Use an absolute path or a path beginning with ~/.")
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        if moving, (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw Failure("Moving or trashing symbolic links is unavailable; use the original path.")
        }
        return url.resolvingSymlinksInPath()
    }

    private func string(_ arguments: [String: JSONValue], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue else { throw Failure("Missing string argument: \(key).") }
        return value
    }

    private func checkMutation(_ url: URL, moving: Bool = false) throws {
        if let reason = AIFileAccessPolicy.refusal(
            path: url.path, home: home.resolvingSymlinksInPath().path,
            revisions: revisions.resolvingSymlinksInPath().path, moving: moving
        ) { throw Failure(reason) }
    }

    private func list(_ arguments: [String: JSONValue]) throws -> [String: Any] {
        let root = try path(arguments)
        try requireDirectory(root)
        var failure: Error?
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: arguments["include_hidden"]?.boolValue == true
                ? [.skipsSubdirectoryDescendants] : [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
            errorHandler: { _, error in failure = error; return false }
        ) else { throw Failure("This directory could not be listed: \(root.path).") }
        let offset = integer(arguments, "offset", default: 0, maximum: 25_000, minimum: 0)
        var skipped = 0
        var entries: [[String: Any]] = []
        var truncated = false
        for case let url as URL in walker {
            try Task.checkCancellation()
            if skipped < offset { skipped += 1; continue }
            if entries.count == 150 { truncated = true; break }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            entries.append([
                "name": url.lastPathComponent, "path": url.path,
                "kind": values.isSymbolicLink == true ? "link" : values.isDirectory == true ? "directory" : "file",
                "bytes": values.fileSize ?? 0
            ])
        }
        if let failure { throw failure }
        let next = offset + entries.count
        return ["path": root.path, "entries": entries, "truncated": truncated, "offset": offset,
                "next_offset": truncated && next <= 25_000 ? next as Any : NSNull(),
                "listing_limit_reached": truncated && next > 25_000]
    }

    private func search(_ arguments: [String: JSONValue], contents: Bool) throws -> [String: Any] {
        let root = try path(arguments)
        try requireDirectory(root)
        let query = try string(arguments, contents ? "query" : "name")
        guard !query.isEmpty else { throw Failure("Search text must not be empty.") }
        let depth = integer(arguments, "max_depth", default: 6, maximum: 20)
        let options: FileManager.DirectoryEnumerationOptions = arguments["include_hidden"]?.boolValue == true
            ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        var unreadable = 0
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: options, errorHandler: { _, _ in unreadable += 1; return true }
        ) else { throw Failure("This directory could not be searched: \(root.path).") }
        let deadline = Date().addingTimeInterval(3)
        var entries = 0
        var bytes = 0
        var matches: [[String: Any]] = []
        var truncated = false
        for case let url as URL in walker {
            try Task.checkCancellation()
            entries += 1
            if entries > 25_000 || matches.count >= 100 || bytes > 32 * 1_048_576 || Date() > deadline {
                truncated = true; break
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isDirectory == true,
                walker.level >= depth || ["node_modules", ".git", ".Trash", ".cache", "DerivedData"]
                    .contains(url.lastPathComponent) {
                walker.skipDescendants()
            }
            if !contents {
                if url.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    matches.append(["path": url.path, "kind": values?.isDirectory == true ? "directory" : "file"])
                }
                continue
            }
            guard values?.isDirectory != true, values?.isSymbolicLink != true,
                let size = values?.fileSize, size <= 1_048_576,
                let data = try? fileData(url), data.count <= 1_048_576,
                let text = String(data: data, encoding: .utf8),
                !text.utf8.contains(0)
            else { continue }
            bytes += data.count
            try forEachLine(in: text) { number, line in
                try Task.checkCancellation()
                if line.localizedCaseInsensitiveContains(query) {
                    matches.append(["path": url.path, "line": number, "text": String(line.prefix(200))])
                }
                if Date() > deadline { truncated = true; return false }
                return matches.count < 100
            }
        }
        return ["path": root.path, "matches": matches, "truncated": truncated,
                "unreadable_paths": unreadable, "scanned_entries": entries]
    }

    private func read(_ arguments: [String: JSONValue]) throws -> [String: Any] {
        let url = try path(arguments)
        let data = try fileData(url)
        let text = try text(data)
        let totalLines = data.reduce(into: 1) { if $1 == 0x0A { $0 += 1 } }
        let start = integer(arguments, "start_line", default: 1, maximum: totalLines + 1)
        let count = integer(arguments, "line_count", default: 200, maximum: 400)
        var selected: [String] = []
        var bytes = 0
        var shortened = false
        try forEachLine(in: text) { number, line in
            try Task.checkCancellation()
            guard number >= start else { return true }
            guard selected.count < count else { return false }
            if bytes + line.utf8.count + 1 > Self.maxOutputBytes {
                shortened = true
                if selected.isEmpty { selected.append(String(line.prefix(Self.maxOutputBytes / 4))) }
                return false
            }
            selected.append(line)
            bytes += line.utf8.count + 1
            return true
        }
        return ["path": url.path, "revision": Self.revision(data), "start_line": start,
                "total_lines": totalLines, "content": selected.joined(separator: "\n"),
                "truncated": shortened || start - 1 + selected.count < totalLines]
    }

    private func mutate(_ name: String, _ arguments: [String: JSONValue]) throws -> [String: Any] {
        try Task.checkCancellation()
        if name == "restore_file" { return try restore(arguments) }
        let moving = name == "move_path" || name == "trash_path"
        let url = try path(arguments, moving: moving)
        try checkMutation(url, moving: moving)
        switch name {
        case "write_file", "edit_file":
            let old = FileManager.default.fileExists(atPath: url.path) ? try fileData(url) : nil
            let expected = try string(arguments, "expected_revision")
            guard expected == (old.map(Self.revision) ?? "missing") else {
                throw Failure("The file changed since it was read. Read it again before editing.")
            }
            let content: String
            if name == "edit_file" {
                guard let old else { throw Failure("The file does not exist.") }
                var source = try text(old)
                let needle = try string(arguments, "old_text")
                guard !needle.isEmpty, let match = source.range(of: needle),
                    source.range(of: needle, range: match.upperBound..<source.endIndex) == nil else {
                    throw Failure("old_text must match exactly once. Read more context and try again.")
                }
                source.replaceSubrange(match, with: try string(arguments, "new_text"))
                content = source
            } else { content = try string(arguments, "content") }
            return try write(Data(content.utf8), to: url, replacing: old)
        case "create_directory":
            let existed = FileManager.default.fileExists(atPath: url.path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return ["path": url.path, "created": !existed]
        case "move_path":
            let destination = try path(arguments, key: "destination", moving: true)
            try checkMutation(destination, moving: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw Failure("The destination already exists; it will not be replaced.")
            }
            try FileManager.default.moveItem(at: url, to: destination)
            return ["path": url.path, "destination": destination.path, "moved": true]
        case "trash_path":
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            return ["path": url.path, "trash_path": trashed?.path ?? "", "trashed": true]
        default: throw Failure("Unknown filesystem operation.")
        }
    }

    private func write(_ data: Data, to url: URL, replacing old: Data?) throws -> [String: Any] {
        guard data.count <= Self.maxFileBytes else { throw Failure("The file exceeds the 8 MB editing limit.") }
        let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        let checkpoint = try old.map { try self.checkpoint($0, path: url.path) }
        try Task.checkCancellation()
        if let old, try fileData(url) != old {
            throw Failure("The file changed while its backup was saved. Read it again before editing.")
        }
        try data.write(to: url, options: old == nil ? [.withoutOverwriting] : [.atomic])
        if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        return ["path": url.path, "revision": Self.revision(data), "bytes": data.count,
                "checkpoint": checkpoint.map { $0 as Any } ?? NSNull()]
    }

    private func checkpoint(_ data: Data, path: String) throws -> String {
        let id = UUID().uuidString
        let directory = revisions.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let contents = directory.appendingPathComponent("contents")
        try data.write(to: contents, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contents.path)
        let metadata = try JSONSerialization.data(withJSONObject: ["path": path, "revision": Self.revision(data)])
        try metadata.write(to: directory.appendingPathComponent("metadata.json"), options: [.withoutOverwriting])
        return id
    }

    private func versions(_ arguments: [String: JSONValue]) throws -> [String: Any] {
        let url = try path(arguments)
        guard FileManager.default.fileExists(atPath: revisions.path) else {
            return ["path": url.path, "entries": [], "truncated": false]
        }
        try requireDirectory(revisions)
        var failure: Error?
        guard let walker = FileManager.default.enumerator(
            at: revisions, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
            errorHandler: { _, error in failure = error; return false }
        ) else { throw Failure("File versions could not be listed.") }
        let deadline = Date().addingTimeInterval(3)
        var entries: [[String: Any]] = []
        var truncated = false
        var scanned = 0
        var incomplete = 0
        for case let directory as URL in walker {
            try Task.checkCancellation()
            scanned += 1
            if scanned > 10_000 || Date() > deadline { truncated = true; break }
            guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            guard let data = try? fileData(directory.appendingPathComponent("metadata.json")),
                let metadata = JSONValue(data: data)?.objectValue else { incomplete += 1; continue }
            guard metadata["path"]?.stringValue == url.path else { continue }
            let created = try directory.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
            entries.append(["checkpoint": directory.lastPathComponent,
                            "revision": metadata["revision"]?.stringValue ?? "",
                            "saved_at": created.timeIntervalSince1970])
            entries.sort { ($0["saved_at"] as? Double ?? 0) > ($1["saved_at"] as? Double ?? 0) }
            if entries.count > 20 { entries.removeLast(); truncated = true }
        }
        if let failure { throw failure }
        return ["path": url.path, "entries": entries, "truncated": truncated, "incomplete_versions": incomplete]
    }

    private func restore(_ arguments: [String: JSONValue]) throws -> [String: Any] {
        guard let id = UUID(uuidString: try string(arguments, "checkpoint")) else {
            throw Failure("Invalid file checkpoint ID.")
        }
        let directory = revisions.appendingPathComponent(id.uuidString)
        let metadata = try fileData(directory.appendingPathComponent("metadata.json"))
        guard let stored = JSONValue(data: metadata)?.objectValue else { throw Failure("Invalid file checkpoint.") }
        let url = try path(stored)
        try checkMutation(url)
        let current = FileManager.default.fileExists(atPath: url.path) ? try fileData(url) : nil
        guard try string(arguments, "expected_revision") == (current.map(Self.revision) ?? "missing") else {
            throw Failure("The file changed since it was read. Read it again before restoring.")
        }
        let saved = try fileData(directory.appendingPathComponent("contents"))
        guard Self.revision(saved) == stored["revision"]?.stringValue else {
            throw Failure("This file version is damaged and cannot be restored.")
        }
        return try write(saved, to: url, replacing: current)
    }

    private func withMutationLock<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(revisions.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure("File checkpoints could not be locked.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw Failure("Another filesystem change is in progress. Try again when it finishes.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }

    private func fileData(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Failure("Only regular files can be read or edited.")
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maxFileBytes else {
            throw Failure("The file exceeds the 8 MB reading limit.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxFileBytes + 1) ?? Data()
        guard data.count <= Self.maxFileBytes else { throw Failure("The file grew beyond the reading limit.") }
        return data
    }

    private func requireDirectory(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw Failure("This path is not a directory: \(url.path).")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw Failure("This directory is not readable: \(url.path).")
        }
    }

    private func boundedResult(_ result: [String: Any]) throws -> Data {
        var result = result
        var data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        while data.count > Self.maxOutputBytes {
            result["truncated"] = true
            if let entries = result["entries"] as? [[String: Any]], !entries.isEmpty {
                result["entries"] = Array(entries.dropLast())
                if let offset = result["offset"] as? Int {
                    let next = offset + entries.count - 1
                    result["next_offset"] = next <= 25_000 ? next as Any : NSNull()
                    result["listing_limit_reached"] = next > 25_000
                }
            } else if let matches = result["matches"] as? [[String: Any]], !matches.isEmpty {
                result["matches"] = Array(matches.dropLast())
            } else if let content = result["content"] as? String, !content.isEmpty {
                result["content"] = String(content.prefix(content.count / 2))
            } else if let output = result["output"] as? String, !output.isEmpty {
                result["output"] = String(output.suffix(output.count / 2))
            } else { throw Failure("The filesystem result exceeds the output limit.") }
            data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        }
        return data
    }

    private func integer(
        _ arguments: [String: JSONValue], _ key: String, default fallback: Int,
        maximum: Int, minimum: Int = 1
    ) -> Int {
        guard case .number(let value) = arguments[key], value.isFinite else { return fallback }
        return Int(max(Double(minimum), min(value, Double(maximum))))
    }

    private func text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
            throw Failure("This is not a UTF-8 text file.")
        }
        return text
    }

    private func forEachLine(
        in text: String, _ action: (Int, String) throws -> Bool
    ) rethrows {
        let bytes = text.utf8
        var start = bytes.startIndex
        var number = 1
        while true {
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.endIndex
            guard try action(number, String(bytes: bytes[start..<end], encoding: .utf8) ?? "") else { return }
            guard end != bytes.endIndex else { return }
            start = bytes.index(after: end)
            number += 1
        }
    }

    static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
