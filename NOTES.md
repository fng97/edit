# Notes

- Rendering optimisation ideas:
  - Use repeat (REP) when implementing splat?
  - Move cursor instead of sending multiple spaces (splat special case)?
  - Faster if everything fits in render buffer? 16K is not enough at 400x300.

## TODO

- Add `{`, `}`, `_`, and `%` motions.
- Fix all fuzzer bugs.
- Basic undo/redo. For now just individual modifications.
- Basic search (check out `std.ascii`).
- Add visual fuzzing repro replay tool.
- Find and replace.
- Whole line selection mode.
- Fix parser. Implement Paul Williams' ANSI Parser State Machine. See the
  following:
  - https://vt100.net/emu/dec_ansi_parser
  - https://github.com/crossterm-rs/crossterm/tree/master/src/event
  - https://github.com/rockorager/libvaxis/blob/main/src/Parser.zig
- Add wrapping functionality (e.g. for git message formatting).
- Yank, cut, and paste using system clipboard.
- Regex search.
- Word motion improvements: Remove '_' from `alphanumeric`. Make it recognise
  camelCase?
- Go through all functions and try think of more invariants. Aim for at least
  two assertions per function.
- Bring back weighting strategies. Swarm the strategies themselves. Make the
  file look like a file. Same for file name.
- Support mouse scroll.
- Insert mode terminal-like keybinds (e.g. CTRL+W to delete word).
- Add custom in-process fuzzer.
- Add AFL++ fuzzer.
- Add timing instrumentation. Is 2ms max reasonable per-tick?
- The ~ for empty lines should go in the gutter instead of the text section.
