# Notes

- Rendering optimisation ideas:
  - Use repeat (REP) when implementing splat?
  - Move cursor instead of sending multiple spaces (splat special case)?
  - Faster if everything fits in render buffer? 16K is not enough at 400x300.

## TODO

- Limit `tick` error set to things we can't handle to reduce crashes.
- Basic search (check out `std.ascii`).
- Yank, cut, and paste using system clipboard: `CSI ? 2004 h`, `CSI ? 2004 l`,
  `CSI 200 ~`, and `CSI 201 ~`.
- Basic find and replace.
- Can command prompt use scratch buffer and just limit on viewport width?
- Clean up `runFormatter`. Figure out failure modes.
- Display symbol for newlines.
- Newlines should be included when highlighting. I think it's related to the
  above. Can't highlight a blank cell.
- Add `{`, `}`, `_`, and `%` motions.
- Reduce fuzzer error paths. Only generate valid data.
- Add tests for every error path.
- Fix all fuzzer bugs.
- Basic undo/redo. For now just individual modifications.
- Add visual fuzzing repro replay tool.
- Add hard wrapping functionality (e.g. for git message formatting).
- Optimise rendering: keep render the same but double buffer and cell diff.
  Let's us keep rendering simple while reducing writes.
  - Once implemented, do it twice in debug mode so we can compare the result of
    both directly (e.g. using libghostty-vt).
- Regex search.
- Regex find and replace.
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
