{
  description = "A Wayland screenshot tool with OCR and Google Lens support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    adios-flake.url = "github:Mic92/adios-flake";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    inputs@{
      adios-flake,
      self,
      ...
    }:
    adios-flake.lib.mkFlake {
      inherit inputs self;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      modules = [ ];

      perSystem =
        {
          self',
          pkgs,
          ...
        }:
        let
          lib = pkgs.lib;
          treefmtEval = inputs.treefmt-nix.lib.evalModule pkgs {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              shfmt.enable = true;
            };
          };

          runtimeDeps = with pkgs; [
            grim
            imagemagick
            tesseract
            wl-clipboard
            xdg-utils
            libnotify
          ];

          # Copy source files to store
          nshotSrc = pkgs.runCommand "nshot-src" { } ''
            mkdir -p $out/share/nshot
            cp -r ${./.}/* $out/share/nshot/
          '';

          nshotScript = pkgs.writeShellScriptBin "nshot" ''
            exec ${pkgs.quickshell}/bin/quickshell -c ${nshotSrc}/share/nshot -n "$@"
          '';

          nshotPackage = pkgs.symlinkJoin {
            name = "nshot";
            paths = [ nshotScript ];
            buildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram $out/bin/nshot \
                --prefix PATH : ${lib.makeBinPath runtimeDeps}
            '';
          };
        in
        {
          formatter = treefmtEval.config.build.wrapper;

          packages = {
            default = self'.packages.nshot;

            nshot = nshotPackage // {
              meta = {
                description = "A Wayland screenshot tool with OCR and Google Lens support";
                homepage = "https://github.com/lonerOrz/nshot";
                mainProgram = "nshot";
                license = lib.licenses.bsd3;
                maintainers = with lib.maintainers; [ lonerOrz ];
                platforms = [
                  "x86_64-linux"
                  "aarch64-linux"
                ];
              };
            };
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ self'.packages.default ];
            packages =
              with pkgs;
              [
                quickshell
                satty
              ]
              ++ runtimeDeps;
          };
        };
    };
}
