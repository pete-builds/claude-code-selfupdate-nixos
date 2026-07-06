# NixOS module: programs.claude-code
#
# Usage in a system flake:
#   imports = [ inputs.claude-code-selfupdate-nixos.nixosModules.default ];
#   programs.claude-code.enable = true;          # self-updating by default
#   # programs.claude-code.selfUpdate = false;   # pin to the reproducible build instead
#
# Requires `nixpkgs.config.allowUnfree = true` (Claude Code itself is unfree).
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-code;
in
{
  options.programs.claude-code = {
    enable = lib.mkEnableOption "the Claude Code CLI";

    selfUpdate = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the self-updating launcher, which refreshes Claude Code to the
        latest official release when you run `claude` (downloading in the
        background and verifying against Anthropic's own checksum; the pinned
        build stays the fallback). Set false to install only the reproducible
        pinned build, which moves only when you update this flake input.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = if cfg.selfUpdate then pkgs.claude-code-selfupdate else pkgs.claude-code;
      defaultText = lib.literalMD "`pkgs.claude-code-selfupdate` if `selfUpdate`, else `pkgs.claude-code`";
      description = "The Claude Code package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [ self.overlays.default ];
    environment.systemPackages = [ cfg.package ];
  };
}
