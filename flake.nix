{
  description = "Toon, a cartoon rice for the Shady compositor";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      # share/shady/rices/toon: on XDG_DATA_DIRS (a NixOS system package, or
      # programs.shady.rices) next to Shady's own rices, whose Tide it builds
      # on, SHADY_RICE=toon picks it.
      packages = forAllSystems (pkgs: rec {
        toon = pkgs.runCommand "shady-rice-toon" {
          meta = {
            description = "Toon: a cartoon shell for Shady, on Tide's layout and keys";
            license = pkgs.lib.licenses.asl20;
          };
        } ''
          dest=$out/share/shady/rices/toon
          mkdir -p $dest
          cd ${self}
          cp -r config.lua init.lua shell.lua style.lua settings.lua fonts shaders README.md LICENSE $dest/
        '';
        default = toon;
      });
    };
}
