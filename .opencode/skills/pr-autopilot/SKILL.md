---
name: pr-autopilot
description: Fully automate ZigCraft pull request follow-through after creating a PR. Use when asked to watch a PR, react to AI code-review comments, fix CI/test failures, keep updating the branch, and auto-merge only when the PR is green and approved/mergeable.
---

## Role

You are responsible for taking a ZigCraft pull request from creation to a green, mergeable state without stopping early.

Use this skill after creating a PR, or when the user explicitly asks you to monitor and complete an existing PR.

## Hard Rules

- Never push directly to `dev` unless the user explicitly instructs you to do so.
- Keep all changes on the PR branch and push follow-up commits there.
- Target `dev` for PRs unless the user explicitly requests another base branch.
- Do not use force push unless the user explicitly approves it.
- Do not skip hooks or checks unless the user explicitly approves it.
- Do not modify unrelated user changes in the worktree.
- Run all Zig build/test commands through `nix develop --command`.
- Continue the loop until the PR is green and merged, or until blocked by permissions, merge conflicts requiring user judgment, missing secrets, unavailable runners, or an explicitly failing external requirement you cannot fix.
- Only enable or perform auto-merge when the user requested autonomous merge behavior for this PR or workflow.

## Watch Loop

Repeat this loop until the PR is merged or blocked:

1. Inspect the PR state with `gh pr view <pr> --json number,url,state,mergeStateStatus,isDraft,reviewDecision,headRefName,baseRefName,headRefOid,statusCheckRollup,comments,reviews,latestReviews,autoMergeRequest`.
2. Inspect review comments with `gh api repos/:owner/:repo/pulls/<pr>/comments`.
3. Inspect issue-style PR comments with `gh api repos/:owner/:repo/issues/<pr>/comments`.
4. Inspect check runs and workflow runs for the PR head SHA with `gh pr checks <pr>` and `gh run list --branch <head-branch> --limit 20`.
5. If checks are pending or queued, wait and poll again after a bounded delay.
6. If an AI code review or human review reports issues, fix every actionable issue, run relevant local verification, commit, push, and continue watching.
7. If CI or another runner fails, fetch logs, diagnose the root cause, fix it locally, run relevant verification, commit, push, and continue watching.
8. If the branch is out of date and GitHub requires it, update the branch using non-destructive git commands or `gh pr update-branch <pr>` when safe, then continue watching.
9. If all required reviews and checks are passing and the PR is mergeable, enable or perform auto-merge.

Use bounded sleeps between polling attempts. Prefer a 60 second delay for normal CI polling and a shorter delay only for quick local status refreshes.

## Review Handling

Treat these as actionable review sources:

- GitHub pull request review comments.
- GitHub pull request reviews requesting changes.
- Issue-style comments on the PR from automated code-review agents.
- Bot comments that include findings, failed expectations, or requested changes.

When responding to review feedback:

- Resolve the underlying issue in code when it is valid.
- If a comment is clearly stale because the code changed, verify it against the current branch before ignoring it.
- If a requested change is ambiguous, infer the safest minimal fix from the code and tests when possible.
- If a requested change conflicts with project rules or user instructions, stop and report the blocker.
- After pushing fixes, leave a concise PR comment only when useful, such as summarizing what was fixed or explaining why a finding was not applicable.

## CI And Runner Handling

For failed checks:

1. Use `gh pr checks <pr>` to identify the failing check.
2. Use `gh run view <run-id> --log-failed` or `gh run view <run-id> --log` to retrieve relevant logs.
3. Reproduce locally when feasible using project commands from `AGENTS.md`.
4. Fix the root cause, not just the symptom.
5. Run the smallest relevant local verification first, then broader verification when the fix is likely complete.
6. Commit and push the fix to the PR branch.

For ZigCraft, default verification includes:

```bash
nix develop --command zig fmt src/
nix develop --command zig build test
```

Use additional checks when relevant:

```bash
nix develop --command zig build -Doptimize=ReleaseFast
nix develop --command zig build test-integration
nix develop --command zig build test-robustness
```

For runtime, graphics, screenshot, or benchmark failures, load the matching project skill:

- `headless-crash-test`
- `headless-graphics-verification`
- `headless-screenshot`
- `headless-benchmark`

## Merge Criteria

Only merge or enable auto-merge when all are true:

- PR targets `dev` unless the user explicitly requested otherwise.
- PR is not a draft.
- Required checks are passing or GitHub reports the PR as mergeable with checks complete.
- Review decision is approved or not required by branch protection.
- No unresolved actionable AI or human review comments remain.
- The PR branch includes the latest fixes you made.
- The working tree has no uncommitted changes from your PR work.

Prefer GitHub auto-merge when branch protection requires asynchronous checks:

```bash
gh pr merge <pr> --auto --squash
```

If all checks are already green and repository policy allows immediate merge, use the same merge method the repository normally uses. Prefer squash merge unless the PR or repository convention indicates otherwise.

## Blockers

Stop and report clearly if:

- GitHub permissions prevent pushing, viewing logs, enabling auto-merge, or merging.
- Required checks depend on unavailable secrets or external services.
- A failure cannot be reproduced and logs do not identify an actionable cause.
- The PR has merge conflicts requiring product or architectural judgment.
- A reviewer requests a change that contradicts the user's explicit instructions.
- Auto-merge is not enabled or allowed and the repository requires a user action.

When blocked, include the PR URL, current status, the blocker, and the smallest next action needed from the user.
