# aws_zig — AWS clients for Zig

Pure Zig clients for **S3** and **DynamoDB**, built on `std.http.Client` and `std.Io`. Shared SigV4 signing and STS live in an internal `lib` module.

| | |
|--|--|
| Package name | **`aws_zig`** |
| Modules | **`s3`**, **`dynamo`** |
| Minimum Zig | **0.17** |

## Installation

```bash
zig fetch --save git+https://codeberg.org/fellowtraveler/z3.git
# after repo rename: git+https://codeberg.org/fellowtraveler/aws_zig.git
```

```zig
const aws = b.dependency("aws_zig", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("s3", aws.module("s3"));
exe.root_module.addImport("dynamo", aws.module("dynamo")); // optional
```

## Modules

| Module | Role | Docs |
|--------|------|------|
| `s3` | Async S3-compatible client (AWS S3, R2, MinIO, …) | [`src/s3/README.md`](src/s3/README.md) |
| `dynamo` | Minimal DynamoDB client | [`src/dynamo/README.md`](src/dynamo/README.md) |
| `lib` | Internal shared AWS primitives (not required by consumers) | — |

## Tests

```bash
zig build test
zig build integration-test-s3      # needs S3 credentials / endpoint
zig build integration-test-dynamo  # needs Dynamo credentials; skips if missing
zig build integration-test         # both
```

## Layout

```
src/lib/      shared SigV4, STS, helpers
src/s3/       S3 client (+ README)
src/dynamo/   DynamoDB client (+ README)
examples/s3/
examples/dynamo/
```

## License

MIT

## Contributions

Contributors are welcome, we aim for 100% integration test coverage and unit tests where useful.

This project broadly follows the [ghostty AI usage policy](https://github.com/ghostty-org/ghostty/blob/main/).
TL;DR You must disclose AI usage, obvious AI slop will be ignored.
