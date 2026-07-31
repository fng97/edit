# Notes

## Bugs caught by fuzzer

- Didn't handle empty files. When indexing lines,
  `file_bytes[file_bytes.len -1]` overflowed. There were a few other places that
  didn't handle empty files.
- Crashed on long file names. Integer overflow when calculating padding size. In
  other words because it couldn't fit everything on the status line.
- Crashed on long lines. Haven't implemented wrappings so was just asserting on
  line length. Going to avoid wrapping and just only print what fits. Will add
  horizontal scroll later.
- Crashed on too many lines. This was asserted in `indexLines`. Instead, should
  return an error. Reasonable that we might manually edit a file and leave it
  with more lines than before.
- Crashed because viewport was too small. Minimum viewport width depends on
  gutter width which depends on number of lines so can't easily generate valid
  dimensions. Just catch error in the fuzzer.
- A couple overflow bugs to do with the status line once I started fuzzing the
  dimensions. Just hiding the filename and then the cursor indicator if they
  don't fit in the viewport.
- Loads of overflows in `tick()`. Ended up moving checks into a `validate()`
  function. Called in `init()` so that we know the first `render()` call will be
  safe then called at end of `tick()` to check state after input processed.
