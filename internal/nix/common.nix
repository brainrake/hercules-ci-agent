/*

  This file is for options that NixOS and nix-darwin have in common.

  Platform-specific code is in the respective default.nix files.

*/

{ config, lib, options, pkgs, ... }:
let
  inherit (lib)
    filterAttrs
    mkIf
    mkOption
    mkRemovedOptionModule
    mkRenamedOptionModule
    types
    ;
  literalDocBook = lib.literalDocBook or lib.literalExample;
  literalExpression = lib.literalExpression or lib.literalExample;

  cfg =
    config.services.hercules-ci-agent;

  inherit (import ./settings.nix { inherit pkgs lib; }) format settingsModule;

  # TODO (roberth, >=2022) remove
  checkNix =
    if !cfg.checkNix
    then ""
    else if lib.versionAtLeast config.nix.package.version "2.3.10"
    then ""
    else
      pkgs.stdenv.mkDerivation {
        name = "hercules-ci-check-system-nix-src";
        inherit (config.nix.package) src patches;
        dontConfigure = true;
        buildPhase = ''
          echo "Checking in-memory pathInfoCache expiry"
          if ! grep 'PathInfoCacheValue' src/libstore/store-api.hh >/dev/null; then
            cat 1>&2 <<EOF

            You are deploying Hercules CI Agent on a system with an incompatible
            nix-daemon. Please make sure nix.package is set to a Nix version of at
            least 2.3.10 or a master version more recent than Mar 12, 2020.
          EOF
            exit 1
          fi
        '';
        installPhase = "touch $out";
      };

in
{
  imports = [
    (mkRenamedOptionModule [ "services" "hercules-ci-agent" "extraOptions" ] [ "services" "hercules-ci-agent" "settings" ])
    (mkRenamedOptionModule [ "services" "hercules-ci-agent" "baseDirectory" ] [ "services" "hercules-ci-agent" "settings" "baseDirectory" ])
    (mkRenamedOptionModule [ "services" "hercules-ci-agent" "concurrentTasks" ] [ "services" "hercules-ci-agent" "settings" "concurrentTasks" ])
    (mkRemovedOptionModule [ "services" "hercules-ci-agent" "patchNix" ] "Nix versions packaged in this version of Nixpkgs don't need a patched nix-daemon to work correctly in Hercules CI Agent clusters.")
  ];

  options.services.hercules-ci-agent = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable to run Hercules CI Agent as a system service.

        <link xlink:href="https://hercules-ci.com">Hercules CI</link> is a
        continuous integation service that is centered around Nix.

        Support is available at <link xlink:href="mailto:help@hercules-ci.com">help@hercules-ci.com</link>.
      '';
    };
    checkNix = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to make sure that the system's Nix (nix-daemon) is compatible.

        If you set this to false, please keep up with the change log.
      '';
    };
    package = mkOption {
      description = ''
        Package containing the bin/hercules-ci-agent executable.
      '';
      type = types.package;
      default = pkgs.hercules-ci-agent;
      defaultText = literalExpression "pkgs.hercules-ci-agent";
    };
    settings = mkOption {
      description = ''
        These settings are written to the <literal>agent.toml</literal> file.

        Not all settings are listed as options, can be set nonetheless.

        For the exhaustive list of settings, see <link xlink:href="https://docs.hercules-ci.com/hercules-ci/reference/agent-config/"/>.
      '';
      type = types.submoduleWith { modules = [ settingsModule ]; };
    };

    /*
      Internal and/or computed values.

      These are written as options instead of let binding to allow sharing with
      default.nix on both NixOS and nix-darwin.
    */
    tomlFile = mkOption {
      type = types.path;
      internal = true;
      defaultText = literalDocBook "generated <literal>hercules-ci-agent.toml</literal>";
      description = ''
        The fully assembled config file.
      '';
    };
  };

  config = mkIf cfg.enable {
    nix.extraOptions = lib.addContextFrom checkNix ''
      # A store path that was missing at first may well have finished building,
      # even shortly after the previous lookup. This *also* applies to the daemon.
      narinfo-cache-negative-ttl = 0
    '';
    services.hercules-ci-agent = {
      tomlFile =
        format.generate "hercules-ci-agent.toml" cfg.settings;
      settings.config._module.args = {
        packageOption = options.services.hercules-ci-agent.package;
        inherit pkgs;
      };
    };
  };
}
