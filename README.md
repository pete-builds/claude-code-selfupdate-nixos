# claude-code-selfupdate-nixos

Self-updating Claude Code for NixOS. It packages Anthropic's official native
binary, pins it to Anthropic's own published sha256, and keeps it current by
refreshing itself in the background when you run `claude`.

One line: a Nix flake for Claude Code that keeps the official Anthropic binary
current on NixOS without npm globals, third-party binary caches, or waiting on
nixpkgs, while retaining a pinned reproducible fallback.

## Who this is for (and who it isn't)

This is a narrow, high-fit tool, not a mass-market one. It fits you if you:

- Run NixOS and use Claude Code daily, and you're tired of packaging lag when a
  new release fixes something.
- Want Claude Code current without waiting on nixpkgs backports.
- Dislike `curl | bash`, npm global installs, or trusting a third-party binary
  cache, but still want a pinned reproducible fallback.
- Build Claude Code into an actual NixOS dev/workstation config, not a one-off.

It is probably **not** for you if you: don't use Nix; are happy with the
nixpkgs cadence; or want a self-update model that is 100% purely declarative
(the runtime updater is intentionally a pragmatic tradeoff, see
[Caveats](#caveats)).

## Why

Most ways of getting a fast-moving CLI onto NixOS ask you to trust something
extra: a third-party flake's build, a third-party binary cache, or a repacked
artifact. This project keeps the trust surface as small as it can be:

- The binary is Anthropic's **official** native build, fetched from
  `https://downloads.claude.ai/claude-code-releases/<version>/<platform>/claude`
  (with Anthropic's GCS bucket as a fallback mirror).
- Every version is pinned and verified against **Anthropic's own** published
  sha256, taken verbatim from
  `https://downloads.claude.ai/claude-code-releases/<version>/manifest.json`.
- That manifest is checked against **Anthropic's own GPG signature**
  (`manifest.json.sig`) using a key pinned in this repo, so the checksums
  themselves are cryptographically anchored, not just fetched over TLS.
- No third-party flake is required, and no third-party binary cache is required.
  You build locally and can re-verify the signature and hash yourself.

The net trust surface is Anthropic's signing key plus a signature and checksum
you can independently verify.

## Quick start

Try it instantly, no install:

```sh
nix run github:pete-builds/claude-code-selfupdate-nixos
```

Install into your user profile (no root):

```sh
nix profile install github:pete-builds/claude-code-selfupdate-nixos
```

NixOS module. Add the flake as an input, import the module, and enable it:

```nix
{
  inputs.claude-code-selfupdate-nixos.url = "github:pete-builds/claude-code-selfupdate-nixos";

  # in your nixosSystem modules:
  imports = [ inputs.claude-code-selfupdate-nixos.nixosModules.default ];

  nixpkgs.config.allowUnfree = true;   # Claude Code itself is unfree
  programs.claude-code.enable = true;  # self-updating by default

  # Pin to the reproducible build instead of self-updating:
  # programs.claude-code.selfUpdate = false;
}
```

See [`examples/flake.nix`](examples/flake.nix) for a complete system flake.

Overlay. Use it to get `pkgs.claude-code` and `pkgs.claude-code-selfupdate`
anywhere in your config:

```nix
nixpkgs.overlays = [ inputs.claude-code-selfupdate-nixos.overlays.default ];
```

Refresh the pin (regenerate `data/sources.json` from Anthropic's release
channel):

```sh
nix run github:pete-builds/claude-code-selfupdate-nixos#update
```

## Packages

Two packages are exposed:

- `claude-code`: the pinned, reproducible build. It reads `data/sources.json`
  and, on Linux, runs `autoPatchelfHook`. It moves only when you update this
  flake input (or the CI job bumps `data/sources.json` and you pull it).
- `claude-code-selfupdate` (the default): wraps the pinned build with the
  `claude-selfupdate.sh` launcher that self-updates on invocation.

## How the self-update works

The self-updating launcher is designed to never get in your way:

1. On launch it immediately execs the best binary it already has. This is
   instant and works offline. It never blocks you waiting on the network.
2. In the background it checks Anthropic's `/latest` release. If a newer
   version exists, it first verifies Anthropic's GPG signature over that
   release's manifest (against a key pinned in this repo), then downloads the
   binary and verifies it against the sha256 in that signed manifest.
3. A verified download is smoke-tested (`--version`) before it is ever trusted,
   then staged for the **next** launch.
4. The pinned Nix build is always the permanent fallback, so `claude` keeps
   working even if every network step fails.

Disable self-update per run with `CLAUDE_SELFUPDATE=0`, or in the NixOS module
with `programs.claude-code.selfUpdate = false;`.

## Trust and verification

Three properties are worth calling out:

- **Anthropic's GPG signature over the manifest.** Both paths verify Anthropic's
  detached signature (`manifest.json.sig`) over the release `manifest.json`
  before trusting anything it says. Verification uses a public key **pinned in
  this repo** ([`data/claude-code-signing-key.asc`](data/claude-code-signing-key.asc)),
  imported into a throwaway keyring, and it requires the signer's primary-key
  fingerprint to equal `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE` (Anthropic's
  documented release-signing key). A signature from any other key is rejected.
  The build-time updater refuses to write `data/sources.json` on a bad
  signature; the self-updater refuses to stage a download. Since the checksums
  live in the signed manifest, a good signature transitively anchors every
  binary hash.
- **Anthropic's own checksum.** Nothing is ever run without matching the
  sha256 that Anthropic publishes in that signed `manifest.json`. The pinned
  build enforces this at Nix eval/build time; the self-updater enforces it
  again at download time. A mismatch means the download is discarded.
- **Byte-identical run.** A self-updated download is run **unmodified**, that
  is byte-for-byte identical to the file that was checksum-verified. On Linux
  it is executed through Nix's dynamic loader with `--library-path` rather than
  being patched with `patchelf`, so the verified bytes are never rewritten
  before they run. (The pinned build does use `autoPatchelfHook`, because its
  integrity is established at Nix build time rather than at run time.)

You can re-verify any pinned version yourself, end to end, with Anthropic's own
key:

```sh
# 1. Import Anthropic's release signing key and confirm the fingerprint.
curl -fsSL https://downloads.claude.ai/keys/claude-code.asc | gpg --import
gpg --fingerprint security@anthropic.com
#   -> 31DD DE24 DDFA B679 F42D  7BD2 BAA9 29FF 1A7E CACE

# 2. Verify the manifest signature for a version.
REPO=https://downloads.claude.ai/claude-code-releases; VERSION=<version>
curl -fsSLO "$REPO/$VERSION/manifest.json"
curl -fsSLO "$REPO/$VERSION/manifest.json.sig"
gpg --verify manifest.json.sig manifest.json
#   -> Good signature from "Anthropic Claude Code Release Signing ..."

# 3. Compare the manifest's checksums against this repo's pin.
jq .platforms manifest.json   # matches data/sources.json
```

The key committed at
[`data/claude-code-signing-key.asc`](data/claude-code-signing-key.asc) is the
same key at that URL; the fingerprint above is asserted in code so a swapped key
cannot pass silently.

Anthropic publishes detached manifest signatures for releases `2.1.89` and
newer. The pinned version here is well above that floor, so both the CI bump and
the runtime self-updater require a valid signature and fail closed without one.
(Individual Linux binaries are not separately code-signed by Anthropic; the
signed manifest is the integrity anchor for them. macOS and Windows binaries
also carry native code signatures.)

## Prior art and credits

This project stands on the shoulders of two existing flakes that also package
Anthropic's official binary and auto-bump it via CI. Both are worth using and
worth reading:

- [`sadjow/claude-code-nix`](https://github.com/sadjow/claude-code-nix)
- [`ryoppippi/nix-claude-code`](https://github.com/ryoppippi/nix-claude-code)

What is different here, without any knock on those projects:

1. **Self-update happens on invocation.** You do not have to run
   `nix flake update` to move to a newer Claude Code. The launcher stages the
   newest verified release for the next `claude` run.
2. **No required third-party binary cache.** The official binary is verified
   against Anthropic's own checksum, anchored by Anthropic's GPG signature over
   the manifest, and built locally, so you do not have to trust a third-party
   cache to get a fast install.

### How it compares

The table reflects each option's primary documented model. All of these ship
Anthropic's official binary; the differences are in currency, trust, and
reproducibility.

| Option | Stays current without a flake update | No third-party cache required | No npm global | Reproducible pinned fallback |
|---|:---:|:---:|:---:|:---:|
| **This project** | Yes (self-update on launch) | Yes | Yes | Yes |
| nixpkgs `claude-code` | No (waits on nixpkgs) | Yes | Yes | Yes |
| sadjow/claude-code-nix | No (hourly CI + flake update) | No (recommends Cachix) | Yes | Yes |
| ryoppippi/nix-claude-code | No (flake update) | No (uses a binary cache) | Yes | Yes |
| npm global install | Yes (`npm install -g ...@latest`) | Yes | No | No |
| official installer (`curl \| bash`) | Yes | Yes | Yes | No |

## Caveats

- **Runtime self-update is a deliberate tradeoff.** Staging a verified newer
  binary at runtime is, by design, less purely declarative than a pinned flake:
  the exact binary you run can move between flake updates. This is opt-in and
  reversible. Set `programs.claude-code.selfUpdate = false;` (or
  `CLAUDE_SELFUPDATE=0`) and you get a fully pinned, reproducible build with no
  runtime movement. Either way the pinned Nix build remains the fallback, so you
  never end up worse off than the last-known-good version.
- Four platforms are declared (`x86_64-linux`, `aarch64-linux`,
  `x86_64-darwin`, `aarch64-darwin`), but only `x86_64-linux` has been tested
  so far. The others should work; they are not yet verified.
- A self-updated binary runs through Nix's dynamic loader on Linux (via
  `--library-path`), not via `patchelf`. This is intentional (see
  [`docs/DESIGN.md`](docs/DESIGN.md)) and keeps the verified bytes intact.
- The pinned Nix build is always the fallback. If any network or verification
  step fails, `claude` still runs the last-known-good pinned binary.

## License

MIT. See [`LICENSE`](LICENSE). Note that Claude Code itself is unfree; this
repository only covers the packaging.
