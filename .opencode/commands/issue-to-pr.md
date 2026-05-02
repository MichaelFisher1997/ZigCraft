---
description: Implement a GitHub issue and open a PR to dev
agent: build
---
Implement GitHub issue `$ARGUMENTS`, defaulting to issue `647` if no issue number is provided.

Use this workflow:

1. Read the issue and all comments with `gh issue view <issue-number> --comments`.
2. Extract the concrete requirements, acceptance criteria, constraints, and any follow-up decisions from the comments.
3. Inspect the relevant code before editing. Preserve existing behavior outside the issue scope.
4. Implement everything needed to satisfy the issue, using the smallest correct changes.
5. Add or update tests when the change has testable behavior.
6. Format changed Zig files with `nix develop --command zig fmt <paths>`.
7. Sanity check with the most relevant commands, including `nix develop --command zig build test` unless there is a clear reason to run a narrower or broader verification.
8. Create a branch if needed, commit the relevant changes with a conventional commit message, and open a pull request targeting `dev`.
9. Include `Fixes #<issue-number>` or `Closes #<issue-number>` in the PR body when the implementation fully resolves the issue.
10. Return the PR URL and a concise summary of the implementation and verification results.

Follow the repository `AGENTS.md` instructions. Do not force push, skip hooks, or modify unrelated user changes.
