# Standalone NixOS module for om — no flake inputs needed.
# Forked from nina (https://kepr.uk/nina).
#
# Usage (in configuration.nix):
#   imports = [
#     "${builtins.fetchTarball "https://kepr.uk/nina/archive/HEAD.tar.gz"}/nixos-module.nix"
#   ];
#   programs.om.enable = true;
#
# For flake-based configs use the flake input instead — see flake.nix.
{ config, pkgs, lib, ... }:
let
  om-pkg = pkgs.stdenv.mkDerivation {
    pname = "om";
    version = builtins.replaceStrings [ "\n" "\r" " " "\t" ] [ "" "" "" "" ]
      (builtins.readFile ./VERSION);
    src = ./.;
    nativeBuildInputs = [ pkgs.zig_0_16 ];
    dontConfigure = true;
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
      zig build -Doptimize=ReleaseSafe
    '';
    installPhase = "install -Dm755 zig-out/bin/om $out/bin/om";
    meta = {
      description = "NixOS Operations Manager (fork of nina)";
      mainProgram = "om";
    };
  };
  cfg = config.programs.om;
in {
  options.programs.om = {
    enable = lib.mkEnableOption "om, the NixOS helper (fork of nina)";
    package = lib.mkOption {
      type = lib.types.package;
      default = om-pkg;
      description = "The om package to install.";
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
