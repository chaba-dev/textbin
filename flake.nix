{
  description = "Textbin - paste and share snippets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Elixir
            beam.packages.erlang_28.elixir_1_20
            beam.packages.erlang_28.rebar3
            erlang_28

            # Golang
            go
            golangci-lint
            gotests
            gomodifytags
            gore
            gotools
            delve

            # LSPs
            beamPackages.expert
            erlang-language-platform
            gopls

            # Tools
            watchman
            docker-compose
            yamllint
            shfmt
            shellcheck
            git-cliff
            yaml-language-server
            goreleaser
            postgresql
          ];

          shellHook = ''
            export MIX_HOME="$PWD/.nix/mix"
            export HEX_HOME="$PWD/.nix/hex"
            export REBAR_CACHE_DIR="$PWD/.nix/rebar3"
            export ERL_AFLAGS="-kernel shell_history enabled"

            mkdir -p "$MIX_HOME" "$HEX_HOME" "$REBAR_CACHE_DIR"
          '';

        };
      }
    );
}
