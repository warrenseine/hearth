import Foundation
import Testing
@testable import HearthKit

@Suite("Pull request lookup")
struct PullRequestLookupTests {
    @Test("owner/repo from GitHub remotes", arguments: [
        ("git@github.com:heypearl/pearl.git", "heypearl/pearl"),
        ("git@github.com:heypearl/pearl", "heypearl/pearl"),
        ("https://github.com/warrenseine/hearth.git", "warrenseine/hearth"),
        ("https://github.com/warrenseine/hearth\n", "warrenseine/hearth"),
        ("ssh://git@github.com/warrenseine/hearth.git", "warrenseine/hearth"),
    ])
    func remotes(remote: String, expected: String) {
        #expect(PullRequestLookup.gitHubRepository(fromRemote: remote) == expected)
    }

    @Test("non-GitHub remotes are ignored", arguments: [
        "git@gitlab.com:o/r.git", "https://example.com/o/r", "/srv/git/repo.git", "https://github.com/onlyowner",
    ])
    func nonGitHub(remote: String) {
        #expect(PullRequestLookup.gitHubRepository(fromRemote: remote) == nil)
    }

    @Test("looks the PR up by branch name and decodes gh's JSON")
    func lookup() async {
        let runner = ScriptedRunner { executable, arguments in
            switch arguments.first {
            case "branch": return "feature/eng-1\n"
            case "remote": return "git@github.com:heypearl/pearl.git\n"
            default:
                #expect(executable == "/fake/gh")
                #expect(arguments.contains("--head") && arguments.contains("feature/eng-1"))
                #expect(arguments.contains("heypearl/pearl"))
                return #"[{"isDraft":false,"number":10512,"title":"feat: per-schedule channels","state":"OPEN","url":"https://github.com/heypearl/pearl/pull/10512"}]"#
            }
        }
        let pr = await PullRequestLookup(gh: "/fake/gh", runner: runner).pullRequest(in: "/tmp")
        #expect(pr == PullRequest(number: 10512, title: "feat: per-schedule channels", url: URL(string: "https://github.com/heypearl/pearl/pull/10512")!, state: .open, isDraft: false))
    }

    @Test("no lookup on the default branch, and none when gh finds nothing")
    func noPR() async {
        let onMain = ScriptedRunner { _, arguments in
            #expect(arguments.first != "pr")
            return arguments.first == "branch" ? "main" : "git@github.com:o/r.git"
        }
        #expect(await PullRequestLookup(gh: "/fake/gh", runner: onMain).pullRequest(in: "/tmp") == nil)
        let empty = ScriptedRunner { _, arguments in
            switch arguments.first {
            case "branch": "feature/x"
            case "remote": "git@github.com:o/r.git"
            default: "[]"
            }
        }
        #expect(await PullRequestLookup(gh: "/fake/gh", runner: empty).pullRequest(in: "/tmp") == nil)
    }
}

/// Answers each command with canned stdout (exit 0).
private struct ScriptedRunner: ProcessRunning {
    let respond: @Sendable (String, [String]) -> String

    func stream(executable: String, arguments: [String], currentDirectory: URL?, environment: [String: String]?) -> AsyncThrowingStream<ProcessEvent, Error> {
        let output = respond(executable, arguments)
        return AsyncThrowingStream { continuation in
            continuation.yield(.stdout(output))
            continuation.yield(.exit(0))
            continuation.finish()
        }
    }
}
