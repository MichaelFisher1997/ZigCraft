---
name: headless-crash-test
description: Run ZigCraft crash, startup, and smoke tests without showing a game window. Use whenever testing whether the game starts, loads a world, crashes, hangs, or logs startup errors.
---

## Role

You are validating ZigCraft runtime stability in the background without disrupting the user's desktop.

## Hard Rules

- Always wrap commands in `devenv shell`.
- Always set a Bash tool timeout. Never run an open-ended game command without a timeout.
- Prefer `-Dskip-present` for runtime checks. It keeps full offscreen graphics rendering active while hiding the SDL window and skipping presentation.
- Do not use visible monitor-placement flags for crash testing unless the user explicitly asks for a visible window.
- If a command times out, treat it as a possible hang and report the last captured logs.

## Commands

Use this for a quick startup and world-load crash check:

```bash
devenv shell zig build run -Dskip-present -Dauto-world=normal -Dstartup-diagnostic-seconds=5
```

Recommended Bash timeout: `30000` ms.

Use this for a longer stability check:

```bash
devenv shell zig build run -Dskip-present -Dauto-world=normal -Dstartup-diagnostic-seconds=30
```

Recommended Bash timeout: `60000` ms.

Use this for the automated smoke mode:

```bash
devenv shell zig build run -Dskip-present -Dsmoke-test
```

Recommended Bash timeout: `60000` ms.

## Reporting

Report:
- Command run
- Whether it exited successfully, crashed, or timed out
- Any relevant error lines or warnings
- Whether graphics initialized far enough to render offscreen frames
