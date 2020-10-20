# fetch-them-macos-headers

This is a small, simplistic utility that can be used to fetch and copy over a standard set of libc headers
as described [here] on macOS. The intention for this utility is to use it to update the libc headers shipped
with [Zig], and used when cross-compiling to macOS (see [this article] for an amazing description of the `zig cc`
C compiler frontend).

[here]: https://en.wikipedia.org/wiki/C_standard_library
[Zig]: https://ziglang.org
[this article]: https://andrewkelley.me/post/zig-cc-powerful-drop-in-replacement-gcc-clang.html

## Howto

Building is straightforward, although I should point out, with the current limitations of the lld linker,
you should build the project natively on macOS

```
zig build
```

Running the generated binary `fetch_them_macos_headers` will create a new dir `x86_64-macos-gnu` with all
libc headers copied over

```
zig-cache/bin/fetch_them_macos_headers
```

