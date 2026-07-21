# Notes

## Bugs caught by fuzzer

- Didn't handle empty files. When indexing lines, `file_bytes[file_bytes.len -1]` overflowed. There
  were a few other places that didn't handle empty files.
- Crashed on long file names. Integer overflow when calculating padding size. In other words because
  it couldn't fit everything on the status line.
- Crashed on long lines. Haven't implemented wrappings so was just asserting on line length. Going
  to avoid wrapping and just only print what fits. Will add horizontal scroll later.
