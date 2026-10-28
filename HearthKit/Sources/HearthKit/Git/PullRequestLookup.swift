import Foundation

/// The most recent pull request opened from a branch, as `gh pr list --json` reports it.
public struct PullRequest: Sendable, Equatable, Decodable {
    public enum State: String, Sendable, Decodable {
        case open = "OPEN", closed = "CLOSED", merged = "MERGED"
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    public let isDraft: Bool
}

/// Finds the pull request for whatever branch a folder has checked out, by branch name (not by
/// commit: a fresh branch's HEAD is just `main`'s tip, whose `(#1234)` belongs to someone else's
/// squash-merged PR). Shells out to `git` and `gh`, so it reuses the user's `gh auth login`.
public struct PullRequestLookup: Sendable {
    public let gh: String
    private let git: String
    private let runner: any ProcessRunning
    private let environment: [String: String]

    public init(gh: String, git: String = "/usr/bin/git", runner: any ProcessRunning = SubprocessRunner(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.gh = gh
        self.git = git
        self.runner = runner
        // A Finder-launched app has launchd's bare PATH; gh itself runs git and may need it.
        var environment = environment
        environment["PATH"] = ([(gh as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            + [environment["PATH"]].compactMap { $0 }).joined(separator: ":")
        environment["GH_PROMPT_DISABLED"] = "1"
        self.environment = environment
    }

    /// `nil` when `gh` isn't installed: the feature then simply doesn't show.
    public static func located(environment: [String: String] = ProcessInfo.processInfo.environment) -> PullRequestLookup? {
        BinaryLocator(environment: environment).locate("gh").map { PullRequestLookup(gh: $0, environment: environment) }
    }

    /// `nil` for a detached HEAD, the default branch, a non-GitHub origin, no PR, or any failure.
    public func pullRequest(in directory: String) async -> PullRequest? {
        let folder = URL(fileURLWithPath: directory)
        guard let branch = await output(git, ["branch", "--show-current"], in: folder),
              !branch.isEmpty, !["main", "master"].contains(branch),
              let remote = await output(git, ["remote", "get-url", "origin"], in: folder),
              let repository = Self.gitHubRepository(fromRemote: remote),
              let json = await output(gh, ["pr", "list", "-R", repository, "--head", branch, "--state", "all",
                                           "--json", "number,title,url,state,isDraft", "--limit", "1"], in: folder)
        else { return nil }
        return (try? JSONDecoder().decode([PullRequest].self, from: Data(json.utf8)))?.first
    }

    /// `owner/repo` from an SSH (`git@github.com:o/r.git`, `ssh://git@github.com/o/r`) or HTTPS
    /// GitHub remote; `nil` for anything else.
    public static func gitHubRepository(fromRemote remote: String) -> String? {
        var path = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("git@github.com:") {
            path.removeFirst("git@github.com:".count)
        } else if let url = URL(string: path), url.host() == "github.com" {
            path = String(url.path().drop { $0 == "/" })
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return parts.joined(separator: "/")
    }

    private func output(_ executable: String, _ arguments: [String], in folder: URL) async -> String? {
        guard let result = try? await runner.run(executable: executable, arguments: arguments, currentDirectory: folder, environment: environment),
              result.succeeded
        else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
