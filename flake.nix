{
  description = "kelliher-web — shared web hosting infrastructure for *.kelliher.info";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    jack-site.url = "github:jack-work/jack.kelliher.info";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      jack-site,
      ...
    }:
    let
      nixosModule =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.kelliher-web;

          siteSubmodule = lib.types.submodule {
            options = {
              hostnames = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                description = "Hostnames to route to this site";
              };

              root = lib.mkOption {
                type = lib.types.nullOr lib.types.package;
                default = null;
                description = "Nix store path for static site root";
              };

              proxyTo = lib.mkOption {
                type = lib.types.nullOr lib.types.port;
                default = null;
                description = "Local port to reverse proxy to";
              };

              extraConfig = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Extra Caddy directives for this site block";
              };
            };
          };

          # Generate Caddy site blocks from all registered sites
          siteConfigs = lib.mapAttrsToList (
            name: site:
            let
              matcherName = builtins.replaceStrings [ "-" ] [ "_" ] name;
              hostMatcher = "@${matcherName} host ${lib.concatStringsSep " " site.hostnames}";
              handler =
                if site.root != null then
                  ''
                    root * ${site.root}
                    file_server
                  ''
                else
                  ''
                    reverse_proxy localhost:${toString site.proxyTo}
                  '';
            in
            ''
              ${hostMatcher}
              handle @${matcherName} {
                ${handler}
                ${site.extraConfig}
              }
            ''
          ) cfg.sites;

          caddyfile = pkgs.writeText "kelliher-web-Caddyfile" ''
            :${toString cfg.port} {
              ${lib.concatStringsSep "\n" siteConfigs}
              log {
                output stdout
                format console
              }
            }
          '';

          hardenedServiceConfig = {
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            PrivateDevices = true;
            PrivateUsers = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            SystemCallFilter = [ "@system-service" ];
            SystemCallArchitectures = "native";
            SystemCallErrorNumber = "EPERM";
            CapabilityBoundingSet = "";
          };
        in
        {
          imports = [ jack-site.nixosModules.default ];

          options.services.kelliher-web = {
            enable = lib.mkEnableOption "kelliher-web hosting platform";

            port = lib.mkOption {
              type = lib.types.port;
              default = 8780;
              description = "Port for the shared Caddy server";
            };

            tunnelTokenFile = lib.mkOption {
              type = lib.types.path;
              description = "Path to file containing the Cloudflare tunnel token";
            };

            sites = lib.mkOption {
              type = lib.types.attrsOf siteSubmodule;
              default = { };
              description = "Sites to host via Caddy";
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.services.kelliher-web-caddy = {
              description = "kelliher-web — Caddy reverse proxy";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = hardenedServiceConfig // {
                ExecStart = "${pkgs.caddy}/bin/caddy run --adapter caddyfile --config ${caddyfile}";
                Restart = "on-failure";
                RestartSec = 5;
                DynamicUser = true;
              };
            };

            users.users.kelliher-web-tunnel = {
              isSystemUser = true;
              group = "kelliher-web-tunnel";
            };
            users.groups.kelliher-web-tunnel = { };

            systemd.services.kelliher-web-cloudflared = {
              description = "kelliher-web — Cloudflare Tunnel";
              after = [
                "network-online.target"
                "kelliher-web-caddy.service"
              ];
              wants = [ "network-online.target" ];
              wantedBy = [ "multi-user.target" ];
              script = ''
                TOKEN=$(cat ${cfg.tunnelTokenFile})
                exec ${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run --token "$TOKEN"
              '';
              serviceConfig = hardenedServiceConfig // {
                Type = "simple";
                User = "kelliher-web-tunnel";
                Group = "kelliher-web-tunnel";
                Restart = "on-failure";
                RestartSec = 10;
              };
            };
          };
        };
    in
    {
      nixosModules.default = nixosModule;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          name = "kelliher-web";
          buildInputs = with pkgs; [
            opentofu
            sops
            age
            ssh-to-age
            jq
            curl
            git
          ];
          shellHook = ''
            echo ""
            echo "kelliher-web"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  cd terraform/   Manage infra"
            echo ""
          '';
        };
      }
    );
}
