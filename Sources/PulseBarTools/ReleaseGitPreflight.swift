import Foundation

enum ReleaseGitPreflight {
    static func validateTag(_ tag: String, root: URL) throws {
        let ref = "refs/tags/\(tag)"
        let local = try Command.capture("git", ["tag", "--list", tag], cwd: root)
        guard local.isEmpty else { throw ToolError("local tag already exists: \(tag)") }
        let remote = try Command.capture("git", ["ls-remote", "--tags", "origin", ref], cwd: root)
        guard remote.isEmpty else { throw ToolError("remote tag already exists: \(tag)") }
    }

    static func validate(root: URL) throws {
        let branch = try Command.capture("git", ["branch", "--show-current"], cwd: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard branch == "main" else {
            throw ToolError("release must run on the main branch")
        }

        // Fetch the actual remote head, rather than trusting a stale tracking ref.
        try Command.run("git", ["fetch", "origin", "refs/heads/main"], cwd: root)
        do {
            try Command.run("git", ["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"], cwd: root)
        } catch {
            throw ToolError("local main must contain the current origin/main before releasing")
        }
    }
}
