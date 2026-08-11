# kelliher-web — per-service storage volumes.
#
# Volumes are either plain directories (no quota) or ZFS datasets
# (refquota, compression, snapshots). The interface downstream services see
# is identical either way; only the activation oneshot differs. Each volume
# gets a `kelliher-web-volume-<name>` oneshot that creates/reconciles it.
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
          type = lib.types.nullOr (
            lib.types.enum [
              "app"
              "media"
              "critical"
            ]
          );
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

  storageCfg = cfg.storage;

  # Escape a Nix string for safe embedding in a double-quoted shell literal.
  shq =
    s: "\"" + builtins.replaceStrings [ "\\" "\"" "$" "`" ] [ "\\\\" "\\\"" "\\$" "\\`" ] s + "\"";

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
      driftFixups = ''
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
      path =
        with pkgs;
        [
          coreutils
        ]
        ++ lib.optionals isZfs [ zfs ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = script;
    };
in
{
  options.services.kelliher-web = {
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
    # Sorted, deduped list of every declared volume's mountPoint.
    # Consumers use this to bulk-wait on the platform's ensurers
    # via `RequiresMountsFor` without walking `storage.volumes`.
    services.kelliher-web.storage.allMountPoints = lib.sort (a: b: a < b) (
      lib.unique (map (v: v.mountPoint) (lib.attrValues storageCfg.volumes))
    );

    assertions = lib.optionals (storageCfg.enable && storageCfg.backend == "zfs") [
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

    systemd.services = lib.mkIf storageCfg.enable (
      lib.listToAttrs (lib.mapAttrsToList mkVolumeUnit storageCfg.volumes)
    );
  };
}
