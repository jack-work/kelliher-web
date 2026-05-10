# kelliher-web devlog

## 2026-04-09 — Hardening, resume, multi-site groundwork

### Systemd hardening
Applied security hardening to both `jack-site-caddy` and `jack-site-cloudflared` systemd units: `PrivateDevices`, `ProtectKernel*`, `RestrictAddressFamilies`, `RestrictNamespaces`, `LockPersonality`, `MemoryDenyWriteExecute`, `SystemCallFilter`, `SystemCallArchitectures`, `CapabilityBoundingSet=""`. Also added `PrivateUsers` and `SystemCallErrorNumber=EPERM` beyond the original plan.

### Resume download link
Added `resume_kelliher.pdf` to the static site and a download link in the contact section. Briefly explored encrypting it at rest with age, decided against it — this is a cosmetic page, not worth the complexity.

### john.kelliher.info subdomain
Added a second DNS CNAME + tunnel ingress for `john.kelliher.info` via Terraform, pointing at the same Caddy instance. A small inline script swaps the displayed name ("Jack" vs "John") based on `location.hostname`.

### Refactor: kelliher-web + jack.kelliher.info separation
Split the repo into two concerns:

- **kelliher-web** (this repo) — infrastructure: Caddy, cloudflared, Terraform, sops secrets, and a composable `services.kelliher-web.sites.<name>` NixOS option contract. Each site declares `hostnames`, `root` (static) or `proxyTo` (dynamic), and optional `extraConfig` (raw Caddy directives). One Caddy + one cloudflared instance serves all sites.
- **jack.kelliher.info** (separate repo) — the static business card site. Its NixOS module registers itself into `services.kelliher-web.sites.jack-site` when enabled.

GitHub repo renamed from `jack.kelliher.info` to `kelliher-web`. Terraform resources renamed from `jack_site` to `kelliher_web` (use `tofu state mv` to avoid tunnel recreation). Hardening directives factored into a shared `hardenedServiceConfig` attrset.

### Pending deployment steps
- Run git/gh commands to finalize the repo split (see instructions in commit history)
- `tofu state mv` the renamed Terraform resources
- Update system flake: import `kelliher-web` instead of `jack-site`, enable `services.kelliher-web` + `services.jack-site`
- `nixos-rebuild switch`

## 2026-05-10 — Finishing the split

### This repo (kelliher-web)
Cleaned up the repository to match its new role as the platform-only
flake. Removed `www/`, `bun.lock`, `package.json`, `node_modules/`,
`blurb.md`, and the Bun-flavored `CLAUDE.md`. Trimmed `node_modules`
out of `.gitignore`. Rewrote `README.md` to describe the platform
contract instead of the personal site. `nix flake check` evaluates
clean; `flake.lock` now pins `jack-site` at the current
`jack.kelliher.info@master` (commit `23d8665`).

### Pending — jack.kelliher.info repo refactor
`github:jack-work/jack.kelliher.info` still contains the *old*
self-contained module that defines `services.jack-site` with its own
Caddy + cloudflared + tunnel. To match the new contract it needs to be
reduced to:

- a `packages.default` static-site derivation built from `www/`
- a `nixosModules.default` that simply registers itself, e.g.

  ```nix
  { config, lib, pkgs, ... }: {
    options.services.jack-site.enable = lib.mkEnableOption "jack.kelliher.info";
    config = lib.mkIf config.services.jack-site.enable {
      services.kelliher-web.sites.jack-site = {
        hostnames = [ "jack.kelliher.info" "john.kelliher.info" ];
        root = self.packages.${pkgs.system}.default;
        extraConfig = ''
          header {
            X-Content-Type-Options nosniff
            X-Frame-Options DENY
            Referrer-Policy strict-origin-when-cross-origin
          }
          handle /health { respond "OK" 200 }
        '';
      };
    };
  };
  ```

  No more Caddy unit, no more cloudflared unit, no more `tunnelTokenFile`
  on that module — those belong to `services.kelliher-web` now.

After that lands, bump `jack-site` in this flake's lock:

```bash
nix flake lock --update-input jack-site
```

### Pending — Terraform state move
The tunnel + ingress + token resources were renamed `jack_site` →
`kelliher_web`. Run **before** the next `tofu apply` to avoid the
tunnel being destroyed and recreated (which would invalidate the token
and break service):

```bash
cd terraform
tofu state mv \
  cloudflare_zero_trust_tunnel_cloudflared.jack_site \
  cloudflare_zero_trust_tunnel_cloudflared.kelliher_web

tofu state mv \
  cloudflare_zero_trust_tunnel_cloudflared_config.jack_site \
  cloudflare_zero_trust_tunnel_cloudflared_config.kelliher_web

# Data source — usually fine to let tofu re-read, but explicit is safer:
tofu state mv \
  data.cloudflare_zero_trust_tunnel_cloudflared_token.jack_site \
  data.cloudflare_zero_trust_tunnel_cloudflared_token.kelliher_web

tofu plan   # should show no resource changes, only the rename
```

### Pending — system flake on `spain`
Replace the `jack-site` input with both new flakes and enable both
modules:

```nix
inputs.kelliher-web.url = "github:jack-work/kelliher-web";
inputs.jack-site.url    = "github:jack-work/jack.kelliher.info";
# (drop the old jack-site if it pointed at the monolithic flake)

# in the host module:
imports = [
  inputs.kelliher-web.nixosModules.default
  inputs.jack-site.nixosModules.default
];
services.kelliher-web = {
  enable = true;
  tunnelTokenFile = config.sops.secrets.tunnel-token.path;
};
services.jack-site.enable = true;
```

Then:

```bash
sudo nixos-rebuild switch --flake .#spain
systemctl status kelliher-web-caddy kelliher-web-cloudflared
curl -H 'Host: jack.kelliher.info' http://localhost:8780/
curl -H 'Host: john.kelliher.info' http://localhost:8780/
```

### Note on the resume PDF
`www/resume_kelliher.original.pdf` was an untracked working copy from
this directory; deleted locally as part of the split. The current
`www/resume_kelliher.pdf` lives in the `jack.kelliher.info` repo and
should be updated there.
