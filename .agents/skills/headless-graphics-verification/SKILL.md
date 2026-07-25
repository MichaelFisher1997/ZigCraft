---
name: headless-graphics-verification
description: Verify ZigCraft graphics changes without visible windows. Use after changing Vulkan, RHI, shaders, render passes, swapchain/headless code, screenshots, benchmark code, or graphics settings.
---

## Role

You verify graphics-related changes safely in the background using offscreen rendering.

## Hard Rules

- Always wrap commands in `devenv shell`.
- Always set Bash tool timeouts for every run command.
- Use `-Dskip-present` for any command that launches the game unless the user explicitly requests a visible window.
- Run `zig build test` for shader validation after shader or graphics code changes.
- Prefer small, bounded runtime checks over interactive runs.

## Standard Verification Sequence

Format changed Zig files:

```bash
devenv shell zig fmt <changed-zig-files>
```

Recommended Bash timeout: `120000` ms.

Build offscreen graphics mode:

```bash
devenv shell zig build -Dskip-present
```

Recommended Bash timeout: `120000` ms.

Run unit tests and shader validation:

```bash
devenv shell zig build test
```

Recommended Bash timeout: `120000` ms.

Run a bounded offscreen world-load check:

```bash
devenv shell zig build run -Dskip-present -Dauto-world=normal -Dstartup-diagnostic-seconds=5
```

Recommended Bash timeout: `30000` ms.

Run a quick offscreen benchmark if performance may be affected:

```bash
devenv shell zig build benchmark -Dbenchmark-duration=5 -Dbenchmark-output=zig-out/benchmark-smoke.json
```

Recommended Bash timeout: `60000` ms.

## When To Use More Checks

- Screenshot/rendering changes: use the `headless-screenshot` skill.
- Performance changes: use the `headless-benchmark` skill.
- Crash/hang reports: use the `headless-crash-test` skill.

## Reporting

Report the exact commands, pass/fail status, timeouts, and output artifact paths.
