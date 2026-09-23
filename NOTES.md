# Notes

- Rendering optimisation ideas:
  - Use repeat (REP) when implementing splat?
  - Move cursor instead of sending multiple spaces (splat special case)?

## TODO

- Yank, cut, and paste using local buffer.
- Yank, cut, and paste using global buffer.
- Add `{`, `}`, `_`, and `%` motions.
- Whole line selection mode.
- Separate parser fuzzing and do editor fuzzing with only valid inputs
  (implement `TerminalEvent.reader()`?).
- Go through all functions and try think of more invariants. Aim for at least
  two assertions per function.
- Try reusing buffers in fuzzer. Much faster?
- Pass editor limits through init. Lets us vary limits in fuzzer. Also allows
  passing options on the command line, e.g. if we wanna open a huge file.
- Handle opening empty file. Just insert a single newline.
- Handle tabs.
- Support mouse scroll.
- Support --goto={line_number}:{line_offset} arg.
- Insert mode terminal-like keybinds (e.g. CTRL+W to delete word).
- Add custom in-process fuzzer.
- Add AFL++ fuzzer.
- Add timing instrumentation. Is 2ms max reasonable per-tick?
