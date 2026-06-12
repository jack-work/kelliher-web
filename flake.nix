{
  description = "kelliher-web — shared web hosting infrastructure for *.kelliher.info";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
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

              requireAuth = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Gate this site behind the Authelia forward-auth portal.
                  Client-supplied Remote-* headers are stripped before the
                  auth subrequest; on success Authelia's Remote-User,
                  Remote-Groups, Remote-Email and Remote-Name headers are
                  copied onto the upstream request.
                '';
              };
            };
          };

          # Generate Caddy site blocks from all registered sites.
          # Directives run inside a `route` block, i.e. in literal order —
          # crucially the Remote-* strip must precede forward_auth (Caddy's
          # default directive order would run request_header after it).
          authSnippet = ''
            request_header -Remote-User
            request_header -Remote-Groups
            request_header -Remote-Email
            request_header -Remote-Name
            forward_auth ${cfg.forwardAuthAddress} {
              uri /api/authz/forward-auth
              copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
              header_up X-Forwarded-Proto https
            }
          '';

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
                route {
                  ${lib.optionalString site.requireAuth authSnippet}
                  ${site.extraConfig}
                  ${handler}
                }
              }
            ''
          ) cfg.sites;

          caddyfile = pkgs.writeText "kelliher-web-Caddyfile" ''
            {
              servers {
                trusted_proxies static 127.0.0.1/8 ::1
              }
            }
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
          # Generic platform: this module knows about no specific site.
          # Site modules (jack-site, gluck-services, …) register themselves
          # into services.kelliher-web.sites and are imported alongside this
          # module by the host config.
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

            forwardAuthAddress = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1:9091";
              description = "Address of the Authelia forward-auth endpoint used by sites with requireAuth";
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
