import Darwin
import Foundation

/// Discovery only reads literal Host names. OpenSSH resolves all options when connecting.
struct SavedSSHConnections: Sendable {
    var config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    var directory: URL { config.deletingLastPathComponent() }

    func aliases() -> [String] {
        var visited = Set<URL>()
        var names: [String] = []
        var seen = Set<String>()
        func read(_ url: URL) {
            let path = url.resolvingSymlinksInPath().standardizedFileURL
            guard visited.count < 256, visited.insert(path).inserted,
                let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                attrs[.type] as? FileAttributeType == .typeRegular,
                (attrs[.size] as? Int ?? Int.max) <= 2_097_152,
                let content = try? String(contentsOf: path, encoding: .utf8)
            else { return }
            for line in content.split(whereSeparator: \.isNewline) {
                let fields = Self.tokens(String(line))
                switch fields.first?.lowercased() {
                case "host":
                    for name in fields.dropFirst() where (try? DashboardEndpoint(port: 1, sshHost: name)) != nil {
                        if seen.insert(name.lowercased()).inserted { names.append(name) }
                    }
                case "include":
                    for include in fields.dropFirst() {
                        let pattern = (include as NSString).expandingTildeInPath
                        let absolute = pattern.hasPrefix("/") ? pattern : directory.appendingPathComponent(pattern).path
                        var matches = glob_t()
                        defer { globfree(&matches) }
                        if glob(absolute, 0, nil, &matches) == 0 {
                            for i in 0..<Int(matches.gl_pathc) {
                                read(URL(fileURLWithPath: String(cString: matches.gl_pathv[i]!)))
                            }
                        }
                    }
                default: continue
                }
            }
        }
        read(config)
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func tokens(_ line: String) -> [String] {
        var fields: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for c in line {
            if escaped {
                word.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if let q = quote {
                if q == c { quote = nil } else { word.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" && word.isEmpty {
                break
            } else if c.isWhitespace || (c == "=" && fields.count <= 1 && (fields.isEmpty || word.isEmpty)) {
                if !word.isEmpty {
                    fields.append(word)
                    word = ""
                }
            } else {
                word.append(c)
            }
        }
        if !word.isEmpty { fields.append(word) }
        return fields
    }
}
