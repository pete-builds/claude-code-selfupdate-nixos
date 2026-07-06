# Design

This document explains why `claude-code-selfupdate-nixos` is built the way it
is. The short version: NixOS makes in-place self-update awkward, Claude Code is
a Bun single-file executable that does not survive `patchelf`, and we want a
tool that stays current without asking the user to run `nix flake update`. The
design threads all three.

## Why NixOS cannot self-update in place

A conventional CLI updates itself by overwriting its own binary on disk. On
NixOS that binary lives in `/nix/store`, which is **read-only** and
content-addressed. There is nothing to overwrite: the store path is immutable
by design, and rebuilding a new store path is a Nix operation, not something a
running process can do to itself.

So a self-updating launcher on NixOS cannot mutate its own install. Instead it
has to:

- keep any downloaded, newer binary **outside** the store, in a user-writable
  cache (`$XDG_CACHE_HOME/claude-code-selfupdate`), and
- decide at launch time whether to run that cached binary or the pinned
  store binary.

That is exactly what `lib/claude-selfupdate.sh` does. It records the newest
verified download in a small state file and, on each launch, picks the best
binary it has: the cached newer version if present and valid, otherwise the
pinned store build.

## Why we run the raw verified binary through the loader, not patchelf

Claude Code ships as a **Bun single-file executable**. Bun packs the
JavaScript payload and its metadata into a trailer appended to the end of the
ELF file. The ELF header and program headers describe the code; the appended
payload sits past them and is located by offsets baked into the file.

`patchelf` rewrites ELF headers in place to fix up the interpreter and RPATH.
On an ordinary dynamically linked ELF that is fine. On a Bun single-file exe it
is not: rewriting the headers **shifts** the file layout, the appended payload
is no longer where the executable expects it, and the binary segfaults on
startup. The pinned build works around this at Nix build time (it uses
`autoPatchelfHook`, and it sets `dontStrip = true` so stripping cannot corrupt
the trailer either), and that path is tested at build time.

For a **self-updated** download we want a stronger guarantee: the bytes that
run must be byte-for-byte identical to the bytes we checksum-verified against
Anthropic's manifest. If we patched them, the checksum we verified would no
longer describe the file on disk, and we would reintroduce exactly the
corruption risk above.

So instead of patching, we run the raw file through Nix's dynamic loader
explicitly:

```sh
"$CLAUDE_DYNAMIC_LINKER" --library-path "$CLAUDE_LIBRARY_PATH" "$binary" "$@"
```

The loader (`ld-linux`) and the library path are both provided by Nix, wired in
by the wrapper. This satisfies the binary's dynamic linking needs without
touching a single byte of the binary itself. The verified bytes run unmodified.
On Darwin no loader indirection is needed, so the raw binary runs directly.

## The pinned-fallback safety model

Every risky step degrades to the pinned build:

- No network, or the release check times out: run the pinned build.
- `curl`/`jq` missing, or a malformed version string: run the pinned build.
- Download fails, or checksum does not match Anthropic's manifest: discard the
  download, run the pinned build.
- Download verifies but fails its `--version` smoke test: discard it, run the
  pinned build.

The launcher only ever **stages** a newer binary for the next launch after it
has verified and smoke-tested it. The pinned store binary, whose integrity is
established at Nix build time, is the permanent floor. The worst case for a
user is that they keep running the pinned version, which is exactly what a
non-self-updating flake would give them anyway.

## The two-package split

There are two packages on purpose:

- `claude-code` is the pinned, reproducible baseline. It is fully deterministic:
  same `data/sources.json`, same store path. It is the fallback the launcher
  falls back to, and it is what you get if you set `selfUpdate = false`. It is
  also the thing CI builds to prove the pin is valid.
- `claude-code-selfupdate` is the wrapper. It adds the launcher and the runtime
  tools it needs (`curl`, `jq`, `coreutils`, and `flock` on Linux) and injects
  the loader and library path as environment variables. It contains no binary
  of its own; it references the pinned build.

Keeping them separate means the deterministic build stands on its own (auditable,
cacheable, testable) and the self-update behavior is a thin, optional layer on
top rather than something baked into the base package.

## CI bump vs runtime self-update

Two independent mechanisms keep users current, and they do not conflict:

- **CI bump (build-time).** `.github/workflows/update.yml` runs hourly, calls
  `nix run .#update` (which runs `lib/update.sh`), and commits any change to
  `data/sources.json`. This moves the **pinned** version forward for everyone
  who tracks the flake. It is what keeps the reproducible baseline fresh and is
  the only path that benefits `selfUpdate = false` users.
- **Runtime self-update (launch-time).** `lib/claude-selfupdate.sh` moves a
  single user forward between flake updates, by staging the newest verified
  release into their cache on launch.

Think of the CI bump as advancing the floor and the runtime self-update as
letting an individual run ahead of the floor. If self-update is disabled, the CI
bump is the sole update path. If self-update is enabled, the CI bump still
matters: it keeps the guaranteed fallback current, so even a user who never has
network at launch time drifts forward whenever they pull the flake.
