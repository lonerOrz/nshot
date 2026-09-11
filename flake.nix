{
  description = "A Wayland screenshot tool with OCR and Google Lens support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;

          runtimeDeps = with pkgs; [
            curl
            coreutils
            gawk
            grim
            imagemagick
            satty
            tesseract
            wl-clipboard
            xdg-utils
            libnotify
          ];

          nshot = pkgs.stdenv.mkDerivation {
            pname = "nshot";
            version = "0.1.0";

            src = lib.cleanSource ./.;

            nativeBuildInputs = [
              pkgs.makeWrapper
            ];

            # 避免 Qt 钩子拦截，quickshell 已具有完整的 Qt 运行时包装
            dontWrapQtApps = true;

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/share/nshot
              cp -r * $out/share/nshot/

              makeWrapper ${pkgs.quickshell}/bin/quickshell $out/bin/nshot \
                --prefix PATH : ${lib.makeBinPath runtimeDeps} \
                --add-flags "-c $out/share/nshot -n"
              runHook postInstall
            '';

            meta = {
              description = "A Wayland screenshot tool with OCR and Google Lens support";
              homepage = "https://github.com/lonerOrz/nshot";
              mainProgram = "nshot";
              license = lib.licenses.bsd3;
              platforms = lib.platforms.linux;
            };
          };
        in
        {
          default = nshot;
          nshot = nshot;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              quickshell
              nixfmt
            ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
