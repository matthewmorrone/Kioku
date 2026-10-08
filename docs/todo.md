# Todo

Open Kioku work only. Finished items are deleted, not ticked; git history has them. Each entry is
written so a new session can pick it up cold.

## Testing
- [ ] **UI automation tests for the core loop** (notes, lookup/save, study, backup). Store-level
      coverage exists (`CoreLoopSmokeTests`, `AppBackupValidatorTests`); nothing drives the actual UI.
      The `KiokuUITests` target already exists in the project with no source files (the template
      tests were removed in `372c42a`), so this means adding a `KiokuUITests/` folder with XCUITests.
      They run on the phone or in CI; this Mac has no simulator runtime.
