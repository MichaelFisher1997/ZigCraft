# Persistence Golden Fixtures

Golden fixtures capture save files from supported persistence formats and are loaded by `zig build test`.

Update protocol:

1. Keep existing fixtures when compatibility is preserved.
2. Add a new versioned fixture directory for intentional format changes.
3. Add or update a regression test that loads the old fixture through the migration path and the new fixture directly.
4. Do not delete a failing old fixture unless the compatibility break is intentional and documented in the migration PR.
