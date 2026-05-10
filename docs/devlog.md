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
