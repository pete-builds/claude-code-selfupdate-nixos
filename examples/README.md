# Example: NixOS system flake

[`flake.nix`](flake.nix) in this directory is a minimal, complete NixOS system
flake that consumes the module from `claude-code-selfupdate-nixos` and installs
Claude Code.

What it shows:

- Adding `claude-code-selfupdate-nixos` as a flake input.
- Importing `nixosModules.default`.
- Setting `nixpkgs.config.allowUnfree = true` (required, because Claude Code is
  unfree).
- Enabling `programs.claude-code`, which installs the self-updating launcher by
  default.

To use it:

1. Copy `flake.nix` into your own system flake, or merge the relevant pieces
   into your existing one.
2. Replace `my-host` with your machine's hostname and adjust `system` if you are
   not on `x86_64-linux`.
3. Rebuild:

   ```sh
   sudo nixos-rebuild switch --flake .#my-host
   ```

After the rebuild, `claude` is on your `PATH`. On its next launch it will check
Anthropic's release channel in the background and stage any newer, verified
version for the launch after that. To pin to the reproducible build instead,
set `programs.claude-code.selfUpdate = false;`.
