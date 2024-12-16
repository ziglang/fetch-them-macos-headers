# fetch-them-macos-headers

This is a small utility repo that can be used to fetch and generate deduplicated macOS libc headers. The intention for
this utility is to use it to update the libc headers shipped with [Zig], and used when cross-compiling to macOS
(see [this article] for an amazing description of the `zig cc` C compiler frontend).

[Zig]: https://ziglang.org
[this article]: https://andrewkelley.me/post/zig-cc-powerful-drop-in-replacement-gcc-clang.html

## Howto

1. Build

```
$ zig build
```

2. (Optional) Add additional libc headers to `src/headers.c`.

3. Fetch headers into `libc/include/`. The `fetch` command will automatically fetch for both `x86_64` and `aarch64`
   architectures by default.

    1. Fetch from the system-wide, latest SDK.

    ```
    $ ./zig-out/bin/fetch_them_macos_headers fetch
    ```

    2. or fetch from a custom SDK by explicitly specifying sysroot path.

    ```
    $ ./zig-out/bin/fetch_them_macos_headers fetch --sysroot <path>
    ```

    See [Getting older SDKs](#getting-older-sdks) for a guide of how to install additional SDKs for older versions of macOS.

4. Merge `x86_64` and `aarch64` into (new, empty) destination path `any-macos-any`.

```
mkdir headers/any-macos-any
rsync -vaHP headers/aarch64-macos.<VERSION>-none/. headers/any-macos-any/.
rsync -vaHP headers/x86_64-macos.<VERSION>-none/. headers/any-macos-any/.
```

5. Update vendored libc in zig repository.

   1. Replace the contents of `$_ZIG_REPO/lib/libc/include/any-macos-any` with `headers/any-macos-any`,
   and analyze the changes with `git status`.
   Reminder to make certain new files are added, and missing files are removed from the repo.

   2. Update the `MinimalDisplayName` key-value from `$_SDKPATH/SDKSettings.json` -> `$_ZIG_REPO/lib/libc/darwin/SDKSettings.json`.
   The vendored `SDKSettings.json` only requires one kv-pair and is used when zig is linking macho artifacts in order to embed
   the macho load command `LC_BUILD_VERSION` with the correct SDK version.

   3. Copy the text-based definitions for libc stubs from `$_SDKPATH/usr/lib/libSystem.tbd` -> `$_ZIG_REPO/lib/libc/darwin/libSystem.tbd`.

## Getting older SDKs

Thanks to Rasmus Andersson's amazing work on [`llvmbox`](https://github.com/rsms/llvmbox) it is now possible to
download additional, older SDKs on your main Mac, extract them without having to install them, and use the extracted SDKs
with `fetch_them_macos_headers`.

How does it work?

1. Navigate to [Apple's developer portal](https://developer.apple.com/download/all/?q=command%20line) and pick Command Line Tools installers of interest.
2. Mount all of them.
3. Run `unpack_sdks.sh` script.

  ```
  $ ./unpack_sdks.sh .
  ```
  Note that you need `pbzx` in your PATH which you can get via `brew install pbzx` or build from source.

4. You can now pass use the extracted SDKs with `fetch_them_macos_headers` which you will find in `./apple-clts`
  unless you used a different argument to `unpack_sdks.sh`.
