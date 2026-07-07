# Design

This document explains why `claude-code-selfupdate-nixos` is built the way it
is. The short version: NixOS makes in-place self-update awkward, Claude Code is
a Bun single-file executable that only survives a narrow `patchelf` operation,
and we want a tool that stays current without asking the user to run
`nix flake update`. The design threads all three.

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

## Why we patch the interpreter (and only the interpreter) after verifying

Claude Code ships as a **Bun single-file executable**: the JavaScript payload
rides in a trailer appended to the ELF file, located by offsets baked into the
file. That makes it fragile under generic binary surgery. Two facts, both
verified empirically against real releases:

- `patchelf --set-interpreter` alone is safe. It is exactly what
  `autoPatchelfHook` does to the pinned build at Nix build time (the binary's
  `DT_NEEDED` is glibc-only, so no RPATH is ever added), and that path is
  tested on every CI build.
- `patchelf --set-rpath` is **not** safe: growing the RPATH shifts the file
  layout, the Bun trailer is no longer where the executable expects it, and
  the binary segfaults on startup (reproduced on 2.1.202). The launcher never
  sets an RPATH, and `dontStrip = true` keeps `strip` away from the trailer.

An earlier design avoided `patchelf` entirely and ran the raw verified file
through Nix's dynamic loader (`ld-linux --library-path ... binary`). That kept
the bytes pristine but broke Claude Code itself: when the loader is what the
kernel execs, `/proc/self/exe` (Bun's `process.execPath`) points at
**ld-linux**, and Claude Code exports `CLAUDE_CODE_EXECPATH=process.execPath`
into every shell session it spawns. Its built-in `grep`/`rg` shell shims then
`exec` the bare loader, and every `grep` inside a Claude Code session dies
with `-G: error while loading shared libraries`. The binary must be the thing
the kernel execs.

So the order of operations is: download, verify the sha256 against Anthropic's
manifest, **then** set the ELF interpreter on the verified file, smoke-test it,
and stage it. Nothing is patched or executed before its checksum matches, and
the patch itself is a deterministic, interpreter-only rewrite performed by
Nix's own `patchelf` on the local machine. Cache entries staged by older
launcher versions are migrated the same way at launch time (copy, patch,
atomic rename, so running sessions keep their old inode), with the legacy
loader launch kept as a last-resort fallback. On Darwin none of this is
needed; the raw binary runs directly.

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
