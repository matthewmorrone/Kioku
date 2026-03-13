# Copilot Coding Invariants

These are required coding invariants for this repository.

1. Avoid `while true` loops.
   - Prefer explicit loop conditions.
   - For SQLite stepping, use `while stepCode == SQLITE_ROW` and explicitly handle `SQLITE_DONE`.

## Additional Invariants

Add more required invariants below. Copilot should treat them as mandatory.

2. Avoid empty `catch` blocks.
   - Every `catch` must either handle the error meaningfully or rethrow/propagate it.

3. All type declarations must be in their own files.
   - Applies to `struct`, `enum`, `class`, `actor`, and `protocol`.
   - File name must match the type name.
   - Nested type declarations are not allowed.

4. Swift file length limit.
   - Treat file length as a cohesion guardrail, not a proxy for quality.
   - Prefer splitting a Swift file once it approaches 800 lines.
   - Swift files should normally stay under 1,200 lines.
   - If a file grows past that point, split it by responsibility before adding more logic unless there is a strong reason to keep it unified.

5. Organize Swift files by functionality.
    - Prefer grouping files by feature/domain responsibility (for example: reading, notes, dictionary, segmentation, settings).
    - Existing folder names under `Kioku/` are examples, not hard constraints.
    - New folders are allowed when they improve functional cohesion and discoverability.
    - Keep app-shell entry files (`KiokuApp.swift`, `ContentView.swift`, `ContentTab.swift`) easy to locate.

6. Function-level intent comments are required.
    - Every function must include at least one line comment explaining why the function exists.
    - Complex logic inside functions must include concise inline comments explaining intent and non-obvious decisions.

7. UI view component ownership comments are required.
   - Every `View` and `UIViewRepresentable` must include comments describing what screen/component it renders.
   - Complex view hierarchies must include inline comments mapping major blocks to on-screen sections (e.g., header, list, editor, toolbar actions, controls).

8. Respect titleless navigation by default.
   - Do not add `.navigationTitle(...)` to a screen where it has been removed.
   - Only add or restore navigation titles when explicitly requested.

9. Text layout and furigana geometry must use a single TextKit coordinate pipeline.
   - Annotation geometry must be expressed in the text view coordinate space only.
   - Convert TextKit rectangles into text view coordinates by offsetting with `textContainerInset` before rendering.
   - Never cache glyph geometry across scrolling or layout changes.
   - Ensure layout before querying annotation geometry.
   - Never compensate annotation placement using `contentOffset`.
   - Required pipeline: TextKit rect -> text view coordinates -> render annotation.

10. Deinflection behavior must stay data-driven.
   - Do not hardcode Japanese suffix or surface rewrite rules in `Deinflector.swift`.
   - Add or refine deinflection behavior by updating `Resources/deinflection.json` and the generic rule application pipeline.
   - Keep `Deinflector.swift` focused on loading rules, traversing rule states, and generic candidate admission logic.

11. Enforce architecture layer boundaries.
   - App shell code owns startup, dependency wiring, root navigation state, and store injection.
   - Feature UI code may compose screens and dispatch mutations, but must not own lexical processing logic.
   - Feature UI code must not redefine segmentation rules or mutate canonical dictionary state.

12. Keep lexical and rendering side effects constrained.
   - Lexical processing code must not mutate note text.
   - Lexical processing code must not persist derived rendering state.
   - Rendering code must not mutate note text or span definitions.
   - Rendering code must not persist layout artifacts.

13. Preserve span and backup architecture contracts.
   - Persisted spans must remain UTF-16 half-open ranges with full coverage and contiguity invariants.
   - Backup and restore paths must remain full-state only; do not introduce partial backup or partial restore behavior.

14. Preserve architecture non-goals.
   - Do not add cloud-sync requirements as part of core architecture.
   - Do not add network dependency requirements for segmentation.
   - Do not introduce boundary-only segment storage representations.
