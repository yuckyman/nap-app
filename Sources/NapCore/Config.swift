import Foundation

/// Mirrors the python presets. `analysisDimension` is the long edge the
/// segmentation and optical flow run at; exports always use the full scan.
public enum QualityPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case fast, balanced, best

    public var id: String { rawValue }

    public var analysisDimension: Int {
        switch self {
        case .fast: 800
        case .balanced: 1200
        case .best: 1600
        }
    }

    public var gifMaxDimension: Int {
        switch self {
        case .fast: 400
        case .balanced: 600
        case .best: 800
        }
    }

    public var denoise: Bool { self != .fast }

    /// Forward/backward flow agreement doubles the flow cost.
    public var consistencyCheck: Bool { self != .fast }
}

public enum NapEnvironment {
    /// `KEY=VALUE` lines, `#` comments, optional `export`, optional quotes.
    public static func parseDotEnv(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = unescape(String(value.dropFirst().dropLast()))
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }

    public static func loadDotEnv(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parseDotEnv(text)
    }

    /// Expands `$VAR`, `${VAR}`, and a leading `~`.
    public static func expandPath(_ raw: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        var path = raw
        let pattern = try! NSRegularExpression(pattern: #"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"#)
        for match in pattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).reversed() {
            guard let whole = Range(match.range, in: path),
                  let nameRange = Range(match.range(at: 1), in: raw),
                  let value = environment[String(raw[nameRange])] else { continue }
            path.replaceSubrange(whole, with: value)
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// `true`/`false`, plus the usual `1`/`0` and `yes`/`no` spellings.
    public static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }

    /// `~/…` under `home`, an absolute path outside it, or anything else left as written
    /// (`$VAR` and relative paths stay so a later expand can still see them).
    public static func portablePath(_ raw: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        let absolute: String
        if trimmed.hasPrefix("~") {
            absolute = (trimmed as NSString).expandingTildeInPath
        } else if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            return trimmed
        }
        if absolute == home { return "~" }
        if absolute.hasPrefix(home + "/") { return "~" + absolute.dropFirst(home.count) }
        return absolute
    }

    /// Keys the app reads and writes. Order is the order new lines are appended.
    public static let managedKeys = [
        "NAP_INPUT_DIR",
        "NAP_GIF_OUTPUT_DIR",
        "NAP_MP4_OUTPUT_DIR",
        "NAP_STILLS_OUTPUT_DIR",
        "NAP_QUALITY",
        "NAP_MP4_LOOPS",
        "NAP_CENTER_SUBJECT",
    ]

    /// Rewrite `KEY=VALUE` lines for `values`. Empty string clears a key by commenting
    /// its line out. Comments, blank lines, and unknown keys stay put. A commented
    /// `# KEY=…` line is revived instead of appending a second one.
    public static func renderDotEnv(_ text: String, values: [String: String]) -> String {
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n"), lines.last == "" { lines.removeLast() }

        var seen = Set<String>()
        for index in lines.indices {
            guard let key = assignmentKey(lines[index]), values.keys.contains(key) else { continue }
            seen.insert(key)
            let value = values[key] ?? ""
            if value.isEmpty {
                lines[index] = commentedAssignment(lines[index])
            } else if parseDotEnv(lines[index])[key] != value {
                lines[index] = "\(key)=\(quote(value))"
            }
        }

        var missing = values.keys.filter { key in
            guard let value = values[key], !value.isEmpty, !seen.contains(key) else { return false }
            return true
        }
        if !missing.isEmpty {
            for index in lines.indices {
                guard let key = commentedAssignmentKey(lines[index]),
                      missing.contains(key),
                      let value = values[key], !value.isEmpty else { continue }
                lines[index] = "\(key)=\(quote(value))"
                seen.insert(key)
                missing.removeAll { $0 == key }
            }
        }

        let extras = missing.filter { !managedKeys.contains($0) }.sorted()
        let ordered = managedKeys.filter { missing.contains($0) } + extras
        if !ordered.isEmpty {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            let appOnly: Set<String> = ["NAP_QUALITY", "NAP_MP4_LOOPS", "NAP_CENTER_SUBJECT"]
            let needsAppComment = ordered.contains { appOnly.contains($0) }
                && !lines.contains { $0.contains("app settings") }
            var wroteAppComment = false
            for key in ordered {
                if needsAppComment, !wroteAppComment, appOnly.contains(key) {
                    lines.append("# app settings")
                    wroteAppComment = true
                }
                lines.append("\(key)=\(quote(values[key] ?? ""))")
            }
        }

        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write `values` into the dotenv file, creating parent folders. No-op when nothing changed.
    public static func writeDotEnv(at url: URL, values: [String: String]) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let rendered = renderDotEnv(existing, values: values)
        if rendered == existing { return }
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(rendered.utf8).write(to: url, options: .atomic)
        } catch {
            throw WriteError.failed(error.localizedDescription)
        }
    }

    public enum WriteError: LocalizedError, Equatable {
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .failed(let reason): reason
            }
        }
    }

    /// Where the app's `.env` lives.
    /// An explicit path wins (the file the user picked, or `NAP_DOTENV`).
    /// Then the path baked into the app at build time, if that folder is still there.
    /// Then a walk up from the working directory and the executable, looking for `.env` or `.env.example`.
    /// Otherwise `applicationSupport/.env`.
    public static func resolveDotEnvURL(
        explicit: String?,
        bundlePath: String?,
        executable: URL,
        workingDirectory: URL,
        fileExists: (String) -> Bool,
        applicationSupport: URL
    ) -> URL {
        func fileURL(_ raw: String) -> URL {
            URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        }
        let picked = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !picked.isEmpty { return fileURL(picked) }
        if let bundlePath {
            let baked = bundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !baked.isEmpty {
                let url = fileURL(baked)
                if fileExists(url.path) || fileExists(url.deletingLastPathComponent().path) {
                    return url
                }
            }
        }
        let roots = [workingDirectory, executable.deletingLastPathComponent()]
        for start in roots {
            var dir = start.standardizedFileURL
            for _ in 0..<8 {
                let env = dir.appendingPathComponent(".env")
                let example = dir.appendingPathComponent(".env.example")
                if fileExists(env.path) || fileExists(example.path) { return env }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return applicationSupport.appendingPathComponent(".env")
    }

    private static func assignmentKey(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text.hasPrefix("#") { return nil }
        if text.hasPrefix("export ") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        guard let eq = text.firstIndex(of: "=") else { return nil }
        let key = text[..<eq].trimmingCharacters(in: .whitespaces)
        guard isEnvKey(key) else { return nil }
        return key
    }

    private static func commentedAssignmentKey(_ line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        return assignmentKey(text)
    }

    private static func commentedAssignment(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return line }
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return indent + "# " + trimmed
    }

    private static func isEnvKey(_ key: String) -> Bool {
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func quote(_ value: String) -> String {
        let needsQuotes = value.contains { character in
            character.isWhitespace || character == "#" || character == "\"" || character == "'"
        }
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Undoes `quote`'s escapes. A trailing lone `\` is kept.
    private static func unescape(_ value: String) -> String {
        var out = ""
        var escaped = false
        for character in value {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        if escaped { out.append("\\") }
        return out
    }
}
