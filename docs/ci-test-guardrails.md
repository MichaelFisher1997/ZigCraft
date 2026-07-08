# CI Test Guardrails

## ReleaseSafe Unit Tests

Pull requests run `zig build test` in both `Debug` and `ReleaseSafe` through the `Build` workflow. `ReleaseSafe` keeps runtime safety checks enabled while exercising optimized code paths that Debug-only CI can miss.

Run locally:

```bash
nix develop --command zig build -Doptimize=ReleaseSafe test
```

## Coverage

The `Coverage` workflow runs kcov against the unit suite, uploads the generated report to Codecov, and posts a non-blocking PR comment pointing reviewers to the coverage artifact. This is a Phase 1 signal: upload/comment failures do not fail the PR, and the report is intended to establish a stable baseline before a future blocking threshold is enabled.

Run locally:

```bash
nix develop .#ci-unit --command kcov \
  --include-path=src,modules,libs \
  --exclude-path=.zig-cache,zig-cache,assets,docs \
  coverage/kcov \
  zig build test
```

kcov reports line coverage only; branch coverage is not available from this setup.

## Sanitizer Nightly

The `Sanitize` workflow runs nightly and on `workflow_dispatch` with:

```bash
nix develop --command zig build -Dsanitize=address test
```

The project is pinned to Zig 0.16.0. That compiler exposes `-fsanitize-c` and `-fsanitize-thread`, but not an LLVM AddressSanitizer build flag through `std.Build`. The repository keeps `-Dsanitize=address` as the CI entrypoint requested by the audit, and currently maps it to Zig's full C undefined-behavior sanitizer support. Failures fail the scheduled workflow check and should be triaged from the uploaded log artifact.

## Vulkan Validation

The integration and world-smoke CI steps run under Lavapipe with `VK_LAYER_KHRONOS_validation`, core validation, and best-practices validation enabled. Integration tests assert that the RHI reports zero validation errors, smoke-test builds exit non-zero if validation errors are observed before shutdown, and the workflow scans both logs for validation-layer error markers as a final fail-on-error gate.
