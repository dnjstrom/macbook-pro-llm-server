{
  description = "nix-darwin config for the MacBook Pro LLM server";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";

    # Rolling nixpkgs-unstable; FlakeHub publishes it as the 0.1.x series,
    # while the release branches are 0.<yymm>.x (so plain "0" above resolves
    # to the newest release, not unstable).
    nixpkgs-unstable.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";

    nix-darwin = {
      url = "https://flakehub.com/f/nix-darwin/nix-darwin/0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    determinate = {
      url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, ... }@inputs:
    let
      username = "daniel";
      hostname = "llm";
      system = "aarch64-darwin";
    in
    {
      darwinConfigurations.${hostname} = inputs.nix-darwin.lib.darwinSystem {
        inherit system;

        # Lets configuration.nix reach other inputs (e.g. nixpkgs-unstable).
        specialArgs = { inherit inputs username hostname; };

        modules = [
          inputs.determinate.darwinModules.default
          {
            determinateNix.enable = true;

            system.stateVersion = 6;
            system.primaryUser = username;

            users.users.${username} = {
              name = username;
              home = "/Users/${username}";
            };
          }

          ./configuration.nix
        ];
      };

      devShells.${system}.default =
        let
          pkgs = import inputs.nixpkgs { inherit system; };
        in
        pkgs.mkShellNoCC {
          packages = [
            (pkgs.writeShellApplication {
              name = "apply-nix-darwin-configuration";
              runtimeInputs = [
                inputs.nix-darwin.packages.${system}.darwin-rebuild
              ];
              text = ''
                echo "> Applying nix-darwin configuration..."
                sudo darwin-rebuild switch --flake ".#${hostname}"
                echo "> darwin-rebuild switch was successful ✅"
              '';
            })

            self.formatter.${system}
          ];
        };

      formatter.${system} = inputs.nixpkgs.legacyPackages.${system}.nixfmt;
    };
}
