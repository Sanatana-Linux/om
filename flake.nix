{
  description = "om — NixOS Operations Manager (fork of nina)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forSystems = f: nixpkgs.lib.genAttrs systems f;
      version = builtins.replaceStrings [ "\n" "\r" " " "\t" ] [ "" "" "" "" ]
        (builtins.readFile ./VERSION);
    in {
      packages = forSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in rec {
          om = pkgs.stdenv.mkDerivation {
            pname = "om";
            inherit version;
            src = self;
            nativeBuildInputs = [ pkgs.zig_0_16 ];
            dontConfigure = true;
            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              zig build -Doptimize=ReleaseSafe
            '';
            installPhase = ''
              install -Dm755 zig-out/bin/om $out/bin/om
            '';
            meta = with nixpkgs.lib; {
              description = "NixOS Operations Manager (fork of nina)";
              mainProgram = "om";
              platforms = platforms.unix;
              license = licenses.mit;
            };
          };
          default = om;
        }
      );

      nixosModules.default = { config, pkgs, lib, ... }:
        let cfg = config.programs.om;
        in {
          options.programs.om = {
            enable = lib.mkEnableOption "om, the NixOS helper (fork of nina)";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = lib.literalExpression "om.packages.\${pkgs.stdenv.hostPlatform.system}.default";
              description = "The om package to install.";
            };
          };
          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];
          };
        };

      nixosModules.om = self.nixosModules.default;
    };
}
