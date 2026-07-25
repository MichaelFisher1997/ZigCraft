---
description: Implement an issue, open a PR, and autopilot it to green
agent: build
---
Implement GitHub issue `$ARGUMENTS`, then keep working until the pull request is green and merged.

If no issue number is provided, stop and ask the user which GitHub issue to implement before taking any other action.

Use this workflow:

1. Read the issue and all comments with `gh issue view <issue-number> --comments`.
2. Extract the concrete requirements, acceptance criteria, constraints, and any follow-up decisions from the comments.
3. Inspect the relevant code before editing. Preserve existing behavior outside the issue scope.
4. Implement everything needed to satisfy the issue, using the smallest correct changes.
5. Add or update tests when the change has testable behavior.
6. Format changed Zig files with `devenv shell zig fmt <paths>`.
7. Sanity check with the most relevant commands, including `devenv shell zig build test` unless there is a clear reason to run a narrower or broader verification.
8. Create a branch if needed, commit the relevant changes with a conventional commit message, and open a pull request targeting `dev`.
9. Include `Fixes #<issue-number>` in the PR body so GitHub links and auto-closes the implemented issue when the PR merges.
10. Load and follow the `pr-autopilot` skill for the created PR.
11. Watch AI/human review comments, merge-conflict state, GitHub checks, workflow runs, and other runners; fix actionable failures; commit and push follow-up fixes to the PR branch; repeat until the PR is green and mergeable.
12. Auto-merge the PR when the `pr-autopilot` merge criteria are satisfied.
13. As soon as the PR is merged, stop and ignore any still-running runners/checks for that PR.
14. Return the PR URL, merge result, and a concise summary of implementation and verification results.

Follow the repository `AGENTS.md` instructions. Do not force push, skip hooks, push directly to `dev`, or modify unrelated user changes.
