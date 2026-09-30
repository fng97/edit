# Notes

- Rendering optimisation ideas:
  - Use repeat (REP) when implementing splat?
  - Move cursor instead of sending multiple spaces (splat special case)?

## TODO

- Basic undo/redo. For now just individual modifications.
- Basic search.
- Handle tabs: convert to 8 spaces.

- Add `{`, `}`, `_`, and `%` motions.
- Whole line selection mode.
- Yank, cut, and paste using global buffer.
- Regex search.
- Word motion ergonomics. Remove '_' from `alphanumeric`. Make it recognise
  camelCase?
- Go through all functions and try think of more invariants. Aim for at least
  two assertions per function.
- Test if reusing memory in fuzzer is faster? Reuse file buffer, editor struct,
  etc.
- Bring back weighting strategies. Swarm the strategies themselves. Make the
  file look like a file. Same for file name.
- Pass editor limits through init. Lets us vary limits in fuzzer. Also allows
  passing options on the command line, e.g. if we wanna open a huge file.
- Handle opening empty file. Just insert a single newline.
- Support mouse scroll.
- Support --goto={line_number}:{line_offset} arg.
- Insert mode terminal-like keybinds (e.g. CTRL+W to delete word).
- Add custom in-process fuzzer.
- Add AFL++ fuzzer.
- Add timing instrumentation. Is 2ms max reasonable per-tick?
