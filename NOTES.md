# Notes

- Rendering optimisation ideas:
  - Use repeat (REP) when implementing splat?
  - Move cursor instead of sending multiple spaces (splat special case)?

## TODO

- Add tests for ":w", ":wq", and "q".
- Add test for exit without saving promopt.
- Add test for go to line number.
- Add test for user message.
- Add test for file save.
- Add test for select (highlighting escape codes).

- Yank, cut, and paste using local buffer.
- Yank, cut, and paste using global buffer.
- Format on save.
- Add `{`, `}`, `_`, and `%` motions.
- Whole line selection mode.
- Separate parser fuzzing and do editor fuzzing with only valid inputs
  (implement `TerminalEvent.reader()`?).
- Go through all functions and try think of more invariants. Aim for at least
  two assertions per function.
- Handle opening empty file. Just insert a single newline.
- Handle tabs.
- Support mouse scroll.
- Support --goto={line_number}:{line_offset} arg.
- Insert mode terminal-like keybinds (e.g. CTRL+W to delete word).
- Add custom in-process fuzzer.
- Add AFL++ fuzzer.
- Add timing instrumentation. Is 2ms max reasonable per-tick?
- Find reference links for all escape sequences.
