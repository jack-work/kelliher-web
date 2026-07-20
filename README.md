# kelliher-web

Shared web hosting infrastructure for `*.kelliher.info`.

One Caddy instance + one Cloudflare tunnel, fronting any number of
sites. Each site is registered as a NixOS submodule under
`services.kelliher-web.sites.<name>`.

## Architecture

```
                  ┌─────────────────────────────────────┐
                  │      Cloudflare (DNS + Tunnel)      │
                  └──────────────┬──────────────────────┘
                                 │
                  cloudflared ◄──┴──► localhost:8780 (Caddy)
                                            │
                              ┌─────────────┼─────────────┐
                              ▼             ▼             ▼
                          jack.*        john.*        future.*
```

- **`services.kelliher-web`** — the shared Caddy + cloudflared platform
  (this flake's `nixosModules.default`).
- **`services.kelliher-web.sites.<name>`** — site registration:
  `hostnames`, `root` (static) or `proxyTo` (port), `extraConfig`.
- Sites live in their own repos and ship their own NixOS modules that
  populate `services.kelliher-web.sites`. Example:
  [`jack.kelliher.info`](https://github.com/jack-work/jack.kelliher.info).

## Layout

```
flake.nix          NixOS module + devShell
terraform/         Cloudflare tunnel + DNS (OpenTofu)
secrets/           sops-encrypted tunnel token
docs/devlog.md     running notes
```

## Devshell

```bash
nix develop
# -> opentofu, sops, age, ssh-to-age, jq, curl, git
```

## Deployment

System flake imports both this flake and any per-site flakes:

```nix
{
  inputs = {
    kelliher-web.url = "github:jack-work/kelliher-web";
    jack-site.url   = "github:jack-work/jack.kelliher.info";
  };

  outputs = { self, nixpkgs, kelliher-web, jack-site, ... }: {
    nixosConfigurations.spain = nixpkgs.lib.nixosSystem {
      modules = [
        kelliher-web.nixosModules.default
        jack-site.nixosModules.default
        {
          services.kelliher-web = {
            enable = true;
            tunnelTokenFile = config.sops.secrets.tunnel-token.path;
          };
          services.jack-site.enable = true;
        }
      ];
    };
  };
}
```

Then:

```bash
sudo nixos-rebuild switch --flake .
```

## Terraform

```bash
cd terraform
tofu init
tofu plan
tofu apply
```

The tunnel token output is consumed by sops-nix on the host; see
`secrets/tunnel-token.yaml` for the encrypted form.

## Storage (per-service volumes)

The platform exposes `services.kelliher-web.storage` so services can
declare **isolated persistent volumes** without knowing whether they
end up on plain filesystem directories or ZFS datasets. The operator
picks the backend once, at the host level; every consumer sees the
same contract.

### Backends

- **`plain`** (default) — each volume is `mkdir -p`'d on the
  underlying filesystem. No quota enforcement (any `quota =` set is
  logged as advisory to the journal). Fine for laptops, CI, and
  hosts without ZFS.
- **`zfs`** — each volume is a dataset under
  `<pool>/<root>/<name>` created with `compression`, `recordsize`,
  `atime=off`, `xattr=sa`, and optional `refquota` / `refreservation`.
  Datasets are created idempotently; property drift is reconciled
  on every activation. Pool creation is *not* this module's job.

Both backends produce the same guarantees at the mount point:

1. Directory exists.
2. Ownership is `<owner>:<group>`.
3. Mode is `<mode>`.
4. All of the above are settled **before** any consumer service
   starts, via a `kelliher-web-volume-<name>.service` oneshot unit
   ordered `Before = local-fs.target` (zfs) and pulled in by
   `multi-user.target`.

### Declaring a volume

At the host level (typically in `spain-flake` or wherever the
platform is enabled):

```nix
services.kelliher-web.storage = {
  enable  = true;
  backend = "zfs";        # or "plain"
  pool    = "tank";        # zfs only
  root    = "tank/apps";   # zfs only

  volumes.gluck-forms-blobs = {
    mountPoint      = "/var/lib/gluck-forms-blobs";
    owner           = "gluck-forms";
    group           = "gluck-forms";
    mode            = "0750";
    quota           = "20G";       # hard on zfs, advisory on plain
    snapshotProfile = "app";        # for downstream sanoid wiring
  };
};
```

Each volume gets a systemd oneshot named
`kelliher-web-volume-<name>.service`.

### Consumer contract

A service that owns a volume should:

1. **Declare** the volume via
   `services.kelliher-web.storage.volumes.<name>` — mount point,
   ownership, quota, snapshot profile.
2. **Wait** for the platform ensurer in its own unit:

   ```nix
   systemd.services.gluck-forms = {
     after    = [ "kelliher-web-volume-gluck-forms-blobs.service" ];
     requires = [ "kelliher-web-volume-gluck-forms-blobs.service" ];
     unitConfig.RequiresMountsFor = [ "/var/lib/gluck-forms-blobs" ];
     # …
   };
   ```

3. **Not** open-code its own `mkdir` / `chown` / `tmpfiles` rule for
   the mount point. The platform ensurer already did it, and
   double-managing ownership is how `DynamicUser` services get
   surprising `EACCES`.

4. **Read** the state location through an env var (or a module
   option) so the code path is backend-agnostic. Same binary, same
   config, whether the backing store is a plain directory or a ZFS
   dataset.

### `DynamicUser` note

For `DynamicUser = true` services, set `owner = "<service-name>"`.
The volume ensurer will `chown` the mount point to that name; systemd
resolves the transient UID at unit start and re-applies ownership as
needed via `StateDirectory` semantics. The important thing is that the
directory *exists* and is *empty and owned by root* the first time,
which is exactly what the ensurer gives you.

### Derived views

- `services.kelliher-web.storage.allMountPoints` — sorted, deduped
  list of every volume's mountPoint. Handy for a global
  `RequiresMountsFor` on a supervisor unit, or for monitoring.

### Assertions

When `backend = "zfs"`, the module asserts that the host has
`boot.supportedFilesystems` including `"zfs"` and a non-empty
`networking.hostId`. Missing either is caught at eval time, not at
first boot.
