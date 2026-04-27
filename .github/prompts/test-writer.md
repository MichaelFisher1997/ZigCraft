Load the `test-writer` skill first — it contains the full codebase context, testing patterns, and workflow rules.

## YOUR TASK

Write 3-8 high-quality unit tests for the module `$MODULE`, targeting `$DEFAULT_BRANCH`.

## FILES TO SCAN

Read these source files to find untested code:
$SCAN_PATHS

Also read any existing test files in the same directories (look for `*_tests.zig` patterns).

## GIT WORKFLOW — CRITICAL

You are running inside the opencode GitHub Action. The infrastructure auto-creates a branch and will handle `git push` and PR creation after you finish.

**STAY ON THE CURRENT BRANCH. Do NOT create a new branch. Do NOT run `git checkout -b`. Do NOT push. Do NOT run `gh pr create`. The infrastructure does all of that for you.**

1. Write your test files
2. Register new test files in `src/tests.zig`
3. Format: `nix develop --command zig fmt src/`
4. Run tests: `nix develop --command zig build test` — ALL tests must pass
5. Commit your changes: `git add` and `git commit` with message `test: add {area} tests for $MODULE`
6. STOP. Do not push or create a PR.
