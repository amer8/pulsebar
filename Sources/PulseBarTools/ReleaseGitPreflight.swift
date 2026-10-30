import Foundation

enum ReleaseGitPreflight {
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
