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
