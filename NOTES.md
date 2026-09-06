# Notes

- Rendering optimisation ideas:
  - Use repeat (REP) when implementing splat?
  - Move cursor instead of sending multiple spaces (splat special case)?

## TODO

- Remove `'q' => return false` and fix tests.
- Add tests for ":w", ":wq", and "q".
- Add test for go to line number.
- Add test for user message.
- Add test harness.

- Prompt when quitting without saving.
- Format on save.
- Whole line selection mode.
- Separate parser fuzzing and do editor fuzzing with only valid inputs.
  - `TerminalEvent.reader()`?
- Handle tabs.
- Support mouse scroll.
- Support --goto={line_number}:{line_offset} arg.
- Add custom in-process fuzzer.
- Add AFL++ fuzzer.
- Add metrics to fuzzer: show live metrics and optionally include in
  `trace.json`.
- Add timing instrumentation. Is 2ms max reasonable per-tick?
