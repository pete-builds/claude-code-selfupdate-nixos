{
  description = "Self-updating Claude Code for NixOS. Official Anthropic binary, pinned to Anthropic's own published checksum, that refreshes itself when you run `claude`.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      # Pinned, reproducible package (the baseline).
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        rec {
          claude-code = pkgs.callPackage ./pkgs/claude-code.nix { };
          claude-code-selfupdate = pkgs.callPackage ./pkgs/claude-code-selfupdate.nix {
            inherit claude-code;
          };
          default = claude-code-selfupdate;
        }
      );

      # Overlay so `pkgs.claude-code` / `pkgs.claude-code-selfupdate` resolve here.
      overlays.default = final: prev: {
        claude-code = final.callPackage ./pkgs/claude-code.nix { };
        claude-code-selfupdate = final.callPackage ./pkgs/claude-code-selfupdate.nix { };
      };

      # NixOS module: programs.claude-code.* (see modules/claude-code.nix).
      nixosModules.default = import ./modules/claude-code.nix self;

      # `nix run` entrypoints: default = self-updating claude; #update = refresh sources.json.
      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          updater = pkgs.writeShellApplication {
            name = "claude-sources-update";
            runtimeInputs = with pkgs; [ curl jq coreutils gnused gnupg ];
            text = builtins.readFile ./lib/update.sh;
          };
        in
        {
          default = {
            type = "app";
            program = "${self.packages.${system}.claude-code-selfupdate}/bin/claude";
          };
          update = {
            type = "app";
            program = "${updater}/bin/claude-sources-update";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              jq
              curl
              nix-prefetch
              shellcheck
              nixfmt-rfc-style
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
