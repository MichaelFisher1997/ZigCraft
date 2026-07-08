# Visual Regression Tests

`visual-test.yml` captures the menu in Lavapipe headless mode and compares it against `docs/visual-test/golden/menu.png` with ImageMagick RMSE. The golden diff is the primary gate; LLM verification remains a non-blocking diagnostic to explain failures.

## Regenerating The Golden

Run the same capture path used by CI, then replace the golden image after reviewing the result:

```bash
nix develop .#ci-graphics --command zig build run -Dskip-present=true -Dscreenshot-path=docs/visual-test/golden/menu.png
```

CI uses `VISUAL_DIFF_RMSE_TOLERANCE=0.015` to allow small Lavapipe version differences while still catching deterministic layout or rendering regressions.
