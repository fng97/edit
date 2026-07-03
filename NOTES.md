# Notes

## Bugs caught by fuzzer

- Didn't handle empty files. When indexing lines, `file_bytes[file_bytes.len - 1]` overflowed.
