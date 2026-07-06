{
  description = "Example NixOS system using claude-code-selfupdate-nixos";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-code-selfupdate-nixos.url = "github:pete-builds/claude-code-selfupdate-nixos";
  };

  outputs =
    { nixpkgs, claude-code-selfupdate-nixos, ... }:
    {
      # Replace "my-host" with your machine's hostname.
      nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          claude-code-selfupdate-nixos.nixosModules.default

          (
            { ... }:
            {
              # Claude Code is unfree, so this is required.
              nixpkgs.config.allowUnfree = true;

              # Install the self-updating Claude Code launcher.
              programs.claude-code.enable = true;

              # Pin to the reproducible build instead of self-updating:
              # programs.claude-code.selfUpdate = false;

              # ... the rest of your system configuration ...
            }
          )
        ];
      };
    };
}
