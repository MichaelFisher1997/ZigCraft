---
name: headless-screenshot
description: Capture ZigCraft screenshots or visual regression evidence using offscreen/headless rendering. Use whenever asked to take screenshots, inspect visuals, validate rendering, or capture a scene without popping up a window.
---

## Role

You capture visual output from ZigCraft without opening a visible game window.

## Hard Rules

- Always wrap commands in `devenv shell`.
- Always set a Bash tool timeout. Screenshot commands can hang if rendering or world loading stalls.
- Always include `-Dskip-present` unless the user explicitly requests a visible capture.
- Use deterministic launch flags where possible (`-Dauto-world=normal`, `-Dshadow-test-scene`, or other existing scenario flags).
- Write screenshots under `screenshots/` or another explicit user-provided path.

## Commands

General world screenshot:

```bash
devenv shell zig build run -Dskip-present -Dauto-world=normal -Dscreenshot-path=screenshots/headless-capture.png -Dscreenshot-frame=120
```

Recommended Bash timeout: `90000` ms.

Delayed capture after world load:

```bash
devenv shell zig build run -Dskip-present -Dauto-world=normal -Dscreenshot-path=screenshots/headless-capture.png -Dscreenshot-frame=180 -Dscreenshot-delay-seconds=3
```

Recommended Bash timeout: `120000` ms.

Shadow test scene capture:

```bash
devenv shell zig build run -Dskip-present -Dshadow-test-scene -Dscreenshot-path=screenshots/shadow-test.png -Dscreenshot-frame=180
```

Recommended Bash timeout: `120000` ms.

## Verification

After capture:
- Confirm the command exited successfully.
- Confirm the screenshot file exists.
- If useful, inspect image dimensions or attach/read the image with the Read tool.

## Reporting

Report the screenshot path and any warnings that could affect visual validity.
