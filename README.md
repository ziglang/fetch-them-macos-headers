# fetch-them-macos-headers

This is a small utility that can be used to fetch and generate deduplicated macOS libc headers. The intention for
this utility is to use it to update the libc headers shipped with [Zig], and used when cross-compiling to macOS
(see [this article] for an amazing description of the `zig cc` C compiler frontend).

[Zig]: https://ziglang.org
[this article]: https://andrewkelley.me/post/zig-cc-powerful-drop-in-replacement-gcc-clang.html

## Howto

**NOTE: it makes little sense running this utility on a non-macOS host.**

1. Build

```
zig build
```

2. (Optional) Add additional libc headers to `src/headers.c`.

3. Fetch headers into `libc/include/<arch>-macos-gnu`

```
./zig-out/bin/fetch_them_macos_headers fetch
```

4. Generate deduplicated headers dirs in `<destination>` path

```
./zig-out/bin/fetch_them_macos_headers generate <destination>
```

5. (Optional) Copy the contents of `<destination>` into Zig's `lib/libc/include/`, and analyze the changes with
   `git status`.

## Usage

```
Usage: fetch_them_macos_headers fetch [cflags]
       fetch_them_macos_headers generate <destination>

Commands:
  fetch [cflags]              Fetch libc headers into libc/include/<arch>-macos-gnu dir
  generate <destination>      Generate deduplicated dirs { aarch64-macos-none, x86_64-macos-none, any-macos-any }
                              into a given <destination> path

General Options:
-h, --help                    Print this help and exit
```
