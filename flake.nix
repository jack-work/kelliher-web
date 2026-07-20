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

          volumeSubmodule = lib.types.submodule (
            { name, ... }:
            {
              options = {
                mountPoint = lib.mkOption {
                  type = lib.types.path;
                  example = "/var/lib/gluck-forms-blobs";
                  description = "Directory where the volume is mounted / created.";
                };
                owner = lib.mkOption {
                  type = lib.types.str;
                  example = "gluck-forms";
                  description = ''
                    User that will own the mount point after activation. For
                    DynamicUser services, use the service name — systemd's
                    StateDirectory contract will handle chown at unit start
                    when the volume already exists as an empty owned-by-root dir.
                    For static users, use the user name.
                  '';
                };
                group = lib.mkOption {
                  type = lib.types.str;
                  default = "root";
                  description = "Group ownership on the mount point.";
                };
                mode = lib.mkOption {
                  type = lib.types.str;
                  default = "0700";
                  description = "Mode bits on the mount point after chown.";
                };
                quota = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "20G";
                  description = ''
                    Size quota on the volume. Enforced hard by ZFS backend
                    (refquota). Ignored by plain backend (no filesystem-level
                    enforcement — advisory only, printed to journal at
                    activation).
                  '';
                };
                reservation = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "refreservation (ZFS only)";
                };
                recordsize = lib.mkOption {
                  type = lib.types.str;
                  default = "128K";
                  description = "ZFS recordsize (ignored on plain backend)";
                };
                compression = lib.mkOption {
                  type = lib.types.str;
                  default = "zstd";
                  description = "ZFS compression (ignored on plain backend)";
                };
                snapshotProfile = lib.mkOption {
                  type = lib.types.nullOr (lib.types.enum [
                    "app"
                    "media"
                    "critical"
                  ]);
                  default = null;
                  description = ''
                    Sanoid retention profile name. Consumers can post-process
                    this into `services.sanoid.datasets` if they wish. This
                    module does not enable sanoid itself.
                  '';
                };
              };
            }
          );

          siteSubmodule = lib.types.submodule {
            options = {
              hostnames = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  Fully-qualified hostnames for this site. Unioned with
                  the expansion of `subdomains × baseDomains` at the
                  platform level. Use this when a name doesn't fit the
                  base domains — apex records, a legacy zone, a
                  Tailscale hostname, etc. Sites that live entirely on
                  the platform's base domains should prefer `subdomains`.
                '';
              };

              subdomains = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "todo" ];
                description = ''
                  Labels prefixed onto each
                  `services.kelliher-web.baseDomains` entry. Declaring
                  `subdomains = [ "todo" ]` with
                  `baseDomains = [ "kelliher.info" ]` yields
                  `todo.kelliher.info`. The site never has to name the
                  zone — that's the platform's job.
                '';
              };

              root = lib.mkOption {
                type = lib.types.nullOr lib.types.package;
                default = null;
                description = ''
                  Nix store path for static site root. Immutable —
                  serves the build-time contents of the given
                  derivation. Use `rootPath` when the site's contents
                  are a mutable filesystem directory (e.g. a storage
                  volume where files are uploaded at runtime).
                '';
              };

              rootPath = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "/var/lib/gluck-files";
                description = ''
                  Filesystem path for a mutable static site root — a
                  directory whose contents change at runtime. Caddy is
                  pointed at this literal path (no store copy), so
                  uploads/deletes take effect immediately. Mutually
                  exclusive with `root`. Typical use: a platform
                  storage volume mounted at some /var/lib path.
                '';
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

              requiredGroups = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "gluck-calendar-create" ];
                description = ''
                  Application capability groups this site expects to exist
                  in lldap. Read by the identity layer to seed
                  `lldap-bootstrap` and to compose Authelia's 2FA policy
                  automatically; the site itself does not enforce these
                  — the app's own handlers do (via Remote-Groups).
                '';
              };
            };
          };

          # The effective host list for one site: any fully-qualified names
          # it declared, plus every subdomain expanded across every base
          # domain the platform owns. Deduped so overlap doesn't produce
          # duplicate Caddy matchers or Cloudflare DNS entries.
          effectiveHostnames =
            site:
            lib.unique (
              site.hostnames
              ++ lib.concatMap (
                base: map (sub: "${sub}.${base}") site.subdomains
              ) cfg.baseDomains
            );

          # Generate Caddy site blocks from all registered sites.
          # Directives run inside a `route` block, i.e. in literal order —
          # crucially the Remote-* strip must precede forward_auth (Caddy's
          # default directive order would run request_header after it).
          #
          # Bearer-token bypass: for requests that carry an Authorization:
          # Bearer header (i.e. an API client with an OIDC access token from
          # Authelia), skip forward_auth entirely and hand the request to
          # the backend, which is expected to validate the JWT itself. The
          # Remote-* strip still runs — the backend must derive identity
          # from the token, never from headers on a bearer request.
          # Every site block strips client-supplied Remote-* headers
          # unconditionally, whether or not it's gated by forward_auth.
          # Without this, an ungated public site would let any request
          # forge Remote-User to the backend, and any backend that trusts
          # Remote-* (as ours all do) would be spoofable. requireAuth adds
          # the forward_auth step on top; it does not gate the strip.
          stripSnippet = ''
            request_header -Remote-User
            request_header -Remote-Groups
            request_header -Remote-Email
            request_header -Remote-Name
          '';
          authSnippet = ''
            @no_bearer not header Authorization Bearer*
            forward_auth @no_bearer ${cfg.forwardAuthAddress} {
              uri /api/authz/forward-auth
              copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
              header_up X-Forwarded-Proto https
            }
          '';

          siteConfigs = lib.mapAttrsToList (
            name: site:
            let
              matcherName = builtins.replaceStrings [ "-" ] [ "_" ] name;
              hosts = effectiveHostnames site;
              hostMatcher = "@${matcherName} host ${lib.concatStringsSep " " hosts}";
              # Split the handler into a `preHandler` (the `root`
              # directive, which must land before user extraConfig so
              # things like `file_server browse` in extraConfig see a
              # root) and a `terminalHandler` (the actual responder).
              # For `root` (Nix package) we emit both root + file_server
              # ourselves — immutable trees don't want browse and there's
              # nothing for the user to layer on. For `rootPath` (mutable
              # dir) we only set root; the user's extraConfig must call
              # file_server (with `browse` if desired). For `proxyTo` we
              # emit only the terminal reverse_proxy.
              preHandler =
                if site.root != null then
                  "root * ${site.root}"
                else if site.rootPath != null then
                  "root * ${site.rootPath}"
                else
                  "";
              terminalHandler =
                if site.root != null then
                  "file_server"
                else if site.rootPath != null then
                  ""
                else
                  "reverse_proxy localhost:${toString site.proxyTo}";
            in
            ''
              ${hostMatcher}
              handle @${matcherName} {
                route {
                  ${stripSnippet}
                  ${lib.optionalString site.requireAuth authSnippet}
                  ${preHandler}
                  ${site.extraConfig}
                  ${terminalHandler}
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

          storageCfg = cfg.storage;

          # Escape a Nix string for safe embedding in a double-quoted shell literal.
          shq = s: "\"" + builtins.replaceStrings [ "\\" "\"" "$" "`" ] [ "\\\\" "\\\"" "\\$" "\\`" ] s + "\"";

          # Plain-backend activation script for one volume:
          #   mkdir -p / chown / chmod, plus a journal warning when a
          #   quota was set (no fs-level enforcement here).
          plainVolumeScript =
            vol:
            ''
              set -eu
              mkdir -p ${shq vol.mountPoint}
              chown ${shq "${vol.owner}:${vol.group}"} ${shq vol.mountPoint}
              chmod ${shq vol.mode} ${shq vol.mountPoint}
            ''
            + lib.optionalString (vol.quota != null) ''
              echo "warning: quota ${vol.quota} on ${vol.mountPoint} is advisory only on plain backend" >&2
            '';

          # ZFS-backend activation script for one volume. Idempotent:
          #   create the dataset only if missing, then bring properties
          #   into line if they drift, then fix ownership/mode. All zfs
          #   commands should already be on PATH via `path`.
          zfsVolumeScript =
            name: vol:
            let
              dataset = "${storageCfg.root}/${name}";
              # Only set props that make sense; skip null quota/reservation.
              createProps = lib.concatStringsSep " " (
                [
                  "-o mountpoint=${shq vol.mountPoint}"
                  "-o compression=${shq vol.compression}"
                  "-o recordsize=${shq vol.recordsize}"
                  "-o atime=off"
                  "-o xattr=sa"
                ]
                ++ lib.optional (vol.quota != null) "-o refquota=${shq vol.quota}"
                ++ lib.optional (vol.reservation != null) "-o refreservation=${shq vol.reservation}"
              );
              # Property drift reconciliation. `zfs set` is a no-op when
              # the value already matches, so we can just assert-set.
              driftFixups =
                ''
                  # mountpoint
                  cur_mp=$(zfs get -H -o value mountpoint ${shq dataset})
                  if [ "$cur_mp" != ${shq vol.mountPoint} ]; then
                    zfs set mountpoint=${shq vol.mountPoint} ${shq dataset}
                  fi
                  # compression
                  cur_comp=$(zfs get -H -o value compression ${shq dataset})
                  if [ "$cur_comp" != ${shq vol.compression} ]; then
                    zfs set compression=${shq vol.compression} ${shq dataset}
                  fi
                  # recordsize
                  cur_rs=$(zfs get -H -o value recordsize ${shq dataset})
                  if [ "$cur_rs" != ${shq vol.recordsize} ]; then
                    zfs set recordsize=${shq vol.recordsize} ${shq dataset}
                  fi
                ''
                + lib.optionalString (vol.quota != null) ''
                  cur_q=$(zfs get -H -o value refquota ${shq dataset})
                  if [ "$cur_q" != ${shq vol.quota} ]; then
                    zfs set refquota=${shq vol.quota} ${shq dataset}
                  fi
                ''
                + lib.optionalString (vol.reservation != null) ''
                  cur_r=$(zfs get -H -o value refreservation ${shq dataset})
                  if [ "$cur_r" != ${shq vol.reservation} ]; then
                    zfs set refreservation=${shq vol.reservation} ${shq dataset}
                  fi
                '';
            in
            ''
              set -eu
              if ! zfs list -H -o name ${shq dataset} >/dev/null 2>&1; then
                zfs create ${createProps} ${shq dataset}
              fi
              ${driftFixups}
              # ZFS mounts on `zfs create` and again on zfs-mount.service;
              # make sure the directory exists (belt-and-suspenders for
              # the delegation case where mountpoint=legacy or =none).
              mkdir -p ${shq vol.mountPoint}
              chown ${shq "${vol.owner}:${vol.group}"} ${shq vol.mountPoint}
              chmod ${shq vol.mode} ${shq vol.mountPoint}
            '';

          mkVolumeUnit =
            name: vol:
            let
              isZfs = storageCfg.backend == "zfs";
              script = if isZfs then zfsVolumeScript name vol else plainVolumeScript vol;
            in
            lib.nameValuePair "kelliher-web-volume-${name}" {
              description = "kelliher-web volume ensurer — ${name} (${storageCfg.backend})";
              wantedBy = [ "multi-user.target" ];
              before = lib.optionals isZfs [ "local-fs.target" ];
              after = lib.optionals isZfs [ "zfs-import.target" ];
              path = with pkgs; [
                coreutils
              ] ++ lib.optionals isZfs [ zfs ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = script;
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

            baseDomains = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              example = [ "kelliher.info" ];
              description = ''
                Zones this platform serves. Each site's `subdomains` are
                expanded across every entry — declaring
                `subdomains = [ "todo" ]` with
                `baseDomains = [ "kelliher.info" ]` yields
                `todo.kelliher.info`. Sites may also list fully-qualified
                `hostnames` for special cases (apex, mixed zones); the two
                lists are unioned.
              '';
            };

            allHostnames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              # Not readOnly=true — the module itself sets this in
              # config below, and readOnly forbids all writers including
              # the module. Convention only: consumers read, module writes.
              description = ''
                Read-only view (by convention): every public hostname
                across every enabled site, with `subdomains × baseDomains`
                already expanded and duplicates removed. Consumers
                (Terraform tfvars generators, monitoring, etc.) should
                read this rather than walking `sites.*.hostnames`
                themselves so the subdomain/base-domain composition
                happens in one place.
              '';
            };

            allAuthenticatedHostnames = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Read-only view: every hostname whose site has
                `requireAuth = true`. Meant for the identity layer
                (Authelia's access_control rules) so gated sites don't
                have to be hand-listed twice.
              '';
            };

            allRequiredGroups = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Read-only view: union of every site's `requiredGroups`.
                Meant for `lldap-bootstrap` so app capability groups get
                created without editing identity.nix per new service.
              '';
            };

            sites = lib.mkOption {
              type = lib.types.attrsOf siteSubmodule;
              default = { };
              description = "Sites to host via Caddy";
            };

            storage = {
              enable = lib.mkEnableOption "per-service storage volumes";

              backend = lib.mkOption {
                type = lib.types.enum [
                  "plain"
                  "zfs"
                ];
                default = "plain";
                description = ''
                  "plain" — volumes are directories on the underlying filesystem; no quotas.
                  "zfs"   — volumes are ZFS datasets on `pool/root/<name>`; quotas, compression,
                            snapshots per the sanoid profile.
                  The interface downstream services see is identical either way.
                '';
              };

              pool = lib.mkOption {
                type = lib.types.str;
                default = "tank";
                description = "ZFS pool name (backend = zfs only)";
              };

              root = lib.mkOption {
                type = lib.types.str;
                default = "tank/apps";
                description = "Parent dataset under which each volume lives (backend = zfs only)";
              };

              volumes = lib.mkOption {
                default = { };
                type = lib.types.attrsOf volumeSubmodule;
                description = "Per-service storage volumes.";
              };

              allMountPoints = lib.mkOption {
                type = lib.types.listOf lib.types.path;
                default = [ ];
                description = ''
                  Read-only view (by convention): sorted, deduped list of
                  every declared volume's mountPoint. Downstream services
                  can `RequiresMountsFor` against these when they want to
                  block until every platform-managed volume is present.
                '';
              };
            };
          };

          config = lib.mkIf cfg.enable {
            # Flatten every site's effective hostnames into one sorted,
            # deduped list — the canonical view for anything downstream
            # of the module (Terraform bridges, health checks, etc.).
            services.kelliher-web.allHostnames = lib.sort (a: b: a < b) (
              lib.unique (lib.concatMap effectiveHostnames (lib.attrValues cfg.sites))
            );

            services.kelliher-web.allAuthenticatedHostnames = lib.sort (a: b: a < b) (
              lib.unique (
                lib.concatMap effectiveHostnames (
                  lib.filter (s: s.requireAuth) (lib.attrValues cfg.sites)
                )
              )
            );

            services.kelliher-web.allRequiredGroups = lib.sort (a: b: a < b) (
              lib.unique (lib.concatMap (s: s.requiredGroups) (lib.attrValues cfg.sites))
            );

            # Sorted, deduped list of every declared volume's mountPoint.
            # Consumers use this to bulk-wait on the platform's ensurers
            # via `RequiresMountsFor` without walking `storage.volumes`.
            services.kelliher-web.storage.allMountPoints = lib.sort (a: b: a < b) (
              lib.unique (map (v: v.mountPoint) (lib.attrValues storageCfg.volumes))
            );

            # Fail loud at eval time if a site declares neither a
            # fully-qualified hostname nor a subdomain: it would produce
            # an empty `host` matcher and match nothing, which is worse
            # than a build break.
            assertions = lib.mapAttrsToList (name: site: {
              assertion = (effectiveHostnames site) != [ ];
              message =
                "kelliher-web: site '${name}' declares no hostnames and no subdomains "
                + "(or subdomains are declared but baseDomains is empty at the platform level)";
            }) cfg.sites
            ++ lib.mapAttrsToList (name: site: {
              assertion = !(site.root != null && site.rootPath != null);
              message =
                "kelliher-web: site '${name}' sets both `root` and `rootPath`; "
                + "pick one (root = immutable Nix store tree, rootPath = mutable filesystem dir).";
            }) cfg.sites
            ++ lib.optionals (storageCfg.enable && storageCfg.backend == "zfs") [
              {
                assertion =
                  let
                    sfs = config.boot.supportedFilesystems or [ ];
                  in
                  if builtins.isList sfs then builtins.elem "zfs" sfs else (sfs.zfs or false);
                message =
                  "kelliher-web.storage.backend = \"zfs\" requires "
                  + "`boot.supportedFilesystems` to include \"zfs\".";
              }
              {
                assertion =
                  let
                    h = config.networking.hostId or null;
                  in
                  h != null && h != "";
                message =
                  "kelliher-web.storage.backend = \"zfs\" requires a non-empty "
                  + "`networking.hostId` (ZFS refuses to import without one).";
              }
            ];

            systemd.services = lib.mkMerge [
              (lib.mkIf storageCfg.enable (
                lib.listToAttrs (lib.mapAttrsToList mkVolumeUnit storageCfg.volumes)
              ))
              {
                kelliher-web-caddy = {
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

                kelliher-web-cloudflared = {
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
              }
            ];

            users.users.kelliher-web-tunnel = {
              isSystemUser = true;
              group = "kelliher-web-tunnel";
            };
            users.groups.kelliher-web-tunnel = { };
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
