# claude-code-selfupdate-nixos

Self-updating Claude Code for NixOS. It packages Anthropic's official native
binary, pins it to Anthropic's own published sha256, and keeps it current by
refreshing itself in the background when you run `claude`.

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
- No third-party flake is required, and no third-party binary cache is required.
  You build locally and can re-verify the hash yourself.

The net trust surface is Anthropic plus a checksum you can independently check.

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
   version exists, it downloads that version and verifies it against
   Anthropic's own published sha256 from the manifest.
3. A verified download is smoke-tested (`--version`) before it is ever trusted,
   then staged for the **next** launch.
4. The pinned Nix build is always the permanent fallback, so `claude` keeps
   working even if every network step fails.

Disable self-update per run with `CLAUDE_SELFUPDATE=0`, or in the NixOS module
with `programs.claude-code.selfUpdate = false;`.

## Trust and verification

Two properties are worth calling out:

- **Anthropic's own checksum.** Nothing is ever run without matching the
  sha256 that Anthropic publishes in its release `manifest.json`. The pinned
  build enforces this at Nix eval/build time; the self-updater enforces it
  again at download time. A mismatch means the download is discarded.
- **Verify first, patch second.** A self-updated download is checksum-verified
  **before** anything touches it. Only then does the launcher set its ELF
  interpreter with `patchelf` (interpreter only, no RPATH), which is the same
  operation `autoPatchelfHook` performs on the pinned build, so the binary can
  be exec'd directly. Direct exec matters: launching through the dynamic
  loader instead makes `process.execPath` point at `ld-linux` and breaks
  Claude Code's own in-session `grep`/`rg` shell shims (see
  [`docs/DESIGN.md`](docs/DESIGN.md)).

You can re-verify any pinned version yourself:

```sh
curl -fsS https://downloads.claude.ai/claude-code-releases/<version>/manifest.json | jq .platforms
```

and compare against `data/sources.json`.

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
   against Anthropic's own checksum and built locally, so you do not have to
   trust a third-party cache to get a fast install.

## Caveats

- Four platforms are declared (`x86_64-linux`, `aarch64-linux`,
  `x86_64-darwin`, `aarch64-darwin`), but only `x86_64-linux` has been tested
  so far. The others should work; they are not yet verified.
- On Linux a self-updated binary gets its ELF interpreter patched (and nothing
  else) after verification, then runs directly. Only `--set-interpreter` is
  safe on this Bun single-file executable; adding an RPATH corrupts it (see
  [`docs/DESIGN.md`](docs/DESIGN.md)).
- The pinned Nix build is always the fallback. If any network or verification
  step fails, `claude` still runs the last-known-good pinned binary.

## License

MIT. See [`LICENSE`](LICENSE). Note that Claude Code itself is unfree; this
repository only covers the packaging.
