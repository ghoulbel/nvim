{
  description = "Neovim configuration";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
    in
    {
      # Consumed by the NixOS flake as `xdg.configFile."nvim".source`.
      # Exposes the config directory itself so home-manager can symlink it.
      configDir = "${self}";
      packages.${system}.default = self;
    };
}
