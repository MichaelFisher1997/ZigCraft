# Visual Regression Tests

`visual-test.yml` captures the menu in Lavapipe headless mode and compares it against `docs/visual-test/golden/menu.png` with ImageMagick RMSE. The capture is recorded after UI composition and before frame submission/presentation, so the copied image is the same final color target in both headless and windowed paths. The comparison rejects effectively black actuals and baselines before calculating RMSE; a black image is not visual-regression evidence.

## Current Baseline Status

The tracked `golden/menu.png` is known to be black and is therefore intentionally **not a valid baseline**. It has not been replaced by this change. Until a reviewed candidate is promoted, CI should fail loudly rather than treating an all-black image as a valid visual result.

## Regenerating The Golden

Capture a candidate through the same path used by CI. Inspect it visually and confirm it is non-black before promoting it:

```bash
devenv shell --profile graphics -- zig build run -Dskip-present=true -Dscreenshot-path=screenshots/menu-candidate.png
magick screenshots/menu-candidate.png -colorspace RGB -format '%[fx:mean]\n' info:
```

Promotion requires a deterministic Lavapipe run, visible menu controls/text, a non-black mean, and reviewer approval. Only then replace `docs/visual-test/golden/menu.png` with the reviewed candidate and rerun the capture/compare command.

CI uses `VISUAL_DIFF_RMSE_TOLERANCE=0.015` to allow small Lavapipe version differences while still catching deterministic layout or rendering regressions.
