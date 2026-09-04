# Notes

- Rendering optimisation ideas:
  - Use repeat (REP) when implementing splat?
  - Move cursor instead of sending multiple spaces (splat special case)?

## TODO

- Add custom in-process fuzzer.
- Add AFL++ fuzzer.
- Add metrics to fuzzer: show live metrics and optionally include in
  `trace.json`.
- Add timing instrumentation. Is 2ms max reasonable per-tick?
