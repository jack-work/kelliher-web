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

## 2026-06-10 — Migration executed; split is live

All pending steps from the 2026-05-10 entry are done. The site is now
served by `kelliher-web-caddy` + `kelliher-web-cloudflared` on spain;
the old `jack-site-*` units and the `jack-site-tunnel` user are gone.

### Repo untangling
The `jack-work/jack.kelliher.info` GitHub URL was silently
*redirecting* to `kelliher-web` (a rename leaves a redirect, and the
new repo was never created). That's why this repo's `origin/master`
had picked up the jack-site registrar commit (`8391cce`) — pushes from
the jack.kelliher.info clone were landing here through the redirect.
Fixed by force-pushing this repo's real master (`2cea766`) and then
creating an actual `jack-work/jack.kelliher.info` repo, which kills
the redirect. Both repos now have independent remotes and histories.

### Terraform state move
Ran the three `tofu state mv` renames (`jack_site` → `kelliher_web`).
`tofu plan`: 0 to add, 0 to destroy — the single in-place "change" is
just live-connection/`account_tag` metadata drift on the tunnel
resource, plus the token data source re-read. Tunnel identity
(`850a2460-…`) preserved; token not invalidated.

### System flake on spain
One deviation from the snippet in the 2026-05-10 entry: do **not**
import both NixOS modules — `kelliher-web.nixosModules.default`
already imports jack-site's module transitively, and importing both
declares `services.jack-site` twice (evaluation error). spain-flake
now imports only the kelliher-web module, keeps `jack-site` as a
direct input with `kelliher-web.inputs.jack-site.follows =
"jack-site"` so site content can be bumped independently of the
platform. Secret renamed `jack-site-tunnel-token` →
`kelliher-web-tunnel-token`, sourced from
`${kelliher-web}/secrets/tunnel.yaml`, owned by `kelliher-web-tunnel`.

Deployed with `deploy .#spain` (deploy-rs, magic rollback) instead of
`nixos-rebuild switch` on the box. Verified: both units active, both
hostnames 200 locally on :8780 and publicly through the tunnel.

### Steady-state edit loop
Edit `www/` in jack.kelliher.info → commit & push → in spain-flake:
`nix flake update jack-site && git commit flake.lock && deploy .#spain`.
Platform changes go through this repo and `nix flake update kelliher-web`.

## 2026-06-11 — Identity layer + authenticated APIs (Authelia + lldap + gluck-services)

Stood up a 2FA-gated public API surface on spain: a stranger hitting
`gluck.kelliher.info` is bounced to an Authelia portal, forced through
password + TOTP, and only then reaches the backend services. An admin
holding the right group can mint accounts through an API call.

### Components and where they live
- **lldap** (`services.lldap`, nixpkgs 0.6.2) — user/group store, SQLite
  under `/var/lib/lldap`. LDAP bound to `127.0.0.1:3890`; web UI on
  `:17170` exposed to the **tailnet only** via
  `networking.firewall.interfaces.tailscale0.allowedTCPPorts`. Never a
  public site or tunnel ingress.
- **Authelia** (`services.authelia.instances.main`, 4.39.12) — portal +
  2FA on loopback `:9091`, SQLite under `/var/lib/authelia-main`,
  `two_factor` policy for `gluck.kelliher.info`, filesystem notifier.
  Authenticates against lldap as `uid=authelia` (a member of
  `lldap_strict_readonly`).
- **gluck-services** (new repo `github:jack-work/gluck-services`) — two
  Python/Flask+waitress services behind the platform:
  `gluck-accounts` (`:9092`, `POST /accounts`) and `gluck-todo`
  (`:9093`, DuckDB CRUD with per-item ACLs). All config in the repo's
  NixOS module; wired into spain-flake as an input.

These live in spain-flake (`identity.nix`) rather than the public
kelliher-web repo, because the secrets wiring and host-specific policy
belong to the host config. The reusable bit — the `requireAuth` option —
went into kelliher-web; everything host-specific stayed in spain-flake.

### The header-trust model (the linchpin)
Backends bind to loopback and trust `Remote-User`/`Remote-Groups`
headers **only** because the sole route to them is Caddy. The new
`services.kelliher-web.sites.<name>.requireAuth` option makes Caddy, for
a gated site: (1) strip any client-supplied `Remote-*` headers, (2)
`forward_auth` to Authelia's `/api/authz/forward-auth`, (3) `copy_headers`
the authenticated `Remote-*` values upstream. Site blocks are now emitted
inside a `route {}` so directive order is literal — Caddy's *default*
order runs `request_header` (the strip) after `forward_auth`, which would
have stripped Authelia's headers instead of the client's. Caddy also now
declares `trusted_proxies static 127.0.0.1/8 ::1` so the cloudflared
hop's `X-Forwarded-*` is honored. **Verified**: a request carrying a
forged `Remote-User: mallory` through the tunnel created a todo owned by
`admin`, not `mallory`; unauthenticated requests (even with forged
headers) get 302'd to the portal and never reach a backend.

### Authorization
Coarse capabilities are lldap groups checked against `Remote-Groups`:
`gluck-todo-create`, `gluck-accounts-create`. Per-todo permissions
(Read/Write/Delete/Share) live in an `acl` table in gluck-todo's own
DuckDB — creator gets all four; `POST /todos/{id}/share` grants a subset
to another user (caller needs Share). Items you can't Read return **404**,
not 403, to avoid existence leaks. All verified end-to-end: second user
saw 404 until shared, then Read→200 / Write→403 / Delete→403 exactly per
the granted rows; a user without `gluck-todo-create` can't create; a
caller without `gluck-accounts-create` gets 403; and `gluck-accounts`
refuses to grant anything outside `^gluck-[a-z0-9-]+$` (so no minting an
`lldap_admin`).

### Bootstrap
`lldap-bootstrap.service` (oneshot, ordered before authelia-main) is
idempotent: it ensures the two capability groups and the service
accounts (`authelia` in `lldap_strict_readonly`, `gluck-accounts` in
`lldap_admin`) exist. The first deploy attempt bricked activation
because Authelia's startup check binds as `uid=authelia` and exits fatal
if the account is missing — deploy-rs magic-rollback caught it and
reverted; the bootstrap unit fixed it on the next deploy.

### Secrets
`secrets/identity.yaml` (sops) holds: lldap JWT secret + admin password,
Authelia JWT/session/storage-encryption keys + LDAP bind password,
gluck-accounts' lldap service password. `.sops.yaml` in spain-flake
gained an operator recipient so these are decryptable on the workstation
too (the pre-existing host secret stays spain-only). lldap and the
bootstrap/oneshots are `DynamicUser`, so their secrets arrive via systemd
`LoadCredential` rather than file ownership; Authelia runs as the static
`authelia-main` user and owns its sops files directly.

### Operational notes / known limitations
- **TOTP enrollment**: neither tool forces a password change on first
  login (no Keycloak-style required actions). Mitigation: minted accounts
  get a random per-account temp password (shown once) + mandatory TOTP
  registration before any access. Residual risk noted; future option is
  emailed one-time enrollment links.
- **Notifier is filesystem**: 2FA/reset links land in
  `/var/lib/authelia-main/notification.txt` on spain (read with
  `sudo cat`), not email. Fine for a single operator; revisit if other
  humans need self-service enrollment.
- **lldap admin login**: the bootstrap `admin` account is the way in to
  mint the first real users / assign capability groups. Its TOTP must be
  enrolled at the portal on first login (any prior enrollment was cleared
  so the operator enrolls their own device).
- **DuckDB single-writer**: gluck-todo must stay a single instance; writes
  are serialized behind one connection + a lock.
- **No programmatic API clients yet**: auth is browser/session-cookie
  based via the portal. The future Authelia-OIDC phase (intentionally not
  enabled here) is what unlocks token-based machine clients.

### Verify loop used
`/api/firstfactor` → `/api/secondfactor/totp` (TOTP via `oathtool`) →
authenticated calls, all with `--resolve` pinned to the Cloudflare edge
so the public tunnel path is exercised, not localhost.

## 2026-06-11 — Invert platform↔site coupling; sites drive Terraform

Two related cleanups so the platform is genuinely generic and a site
configures *all* of its surface — Caddy, DNS, and tunnel ingress — from a
single declaration.

### Inverted the NixOS module dependency
Previously the *generic platform* imported a *specific tenant*: kelliher-web's
module did `imports = [ jack-site.nixosModules.default ]` and carried a
`jack-site` flake input. That was backwards — it forced every kelliher-web
consumer to drag jack-site along, and was the source of the double-declaration
eval error (importing jack-site both transitively and directly).

Now:
- **kelliher-web** has no `jack-site` input and imports no site. It only
  declares `services.kelliher-web.sites` and the Caddy/cloudflared config.
- Each **site module** (jack-site, gluck-services) registers itself into
  `services.kelliher-web.sites.<name>` and is imported **directly** by the
  host config.
- **spain-flake** imports `kelliher-web.nixosModules.default` +
  `jack-site.nixosModules.default` + `gluck-services.nixosModules.default`
  side by side. The `kelliher-web.inputs.jack-site.follows` shim is gone.

The arrow now points the right way: sites depend on the platform contract,
never the reverse. gluck-services already followed this; jack-site now does
too.

### The sites→Terraform contract
`services.kelliher-web.sites.<name>.hostnames` is now the **single source of
truth** for every public name. It already drove Caddy routing; it now drives
Cloudflare DNS and tunnel ingress as well, with no duplicated host lists.

Bridge: spain-flake exposes a flake output `packages.tunnel-hostnames` that
evaluates the host config and emits every registered hostname as
`hostnames.auto.tfvars.json`. Terraform auto-loads that file into
`var.hostnames` and builds both the DNS records and the ingress from it:

```hcl
resource "cloudflare_dns_record" "site" {
  for_each = toset(var.hostnames)
  name     = each.key
  content  = "${...kelliher_web.id}.cfargotunnel.com"
  type     = "CNAME"; proxied = true; ttl = 1
}
# ingress = [for h in var.hostnames : {hostname=h, service=var.tunnel_service}] ++ [404]
```

So a site **self-configures**: declaring a hostname in its Nix module is the
whole story. Workflow to add/rename one:

```bash
# 1. edit the site's services.kelliher-web.sites.<name>.hostnames
# 2. regenerate the tfvars from the evaluated config:
cd spain-flake && nix build .#tunnel-hostnames \
  && install -m644 result ../kelliher-web/terraform/hostnames.auto.tfvars.json
# 3. apply DNS + ingress, then deploy Caddy:
cd ../kelliher-web/terraform && nix run nixpkgs#opentofu -- apply
cd ../../spain-flake && nix flake update <site> && nix develop -c deploy .#spain
```

The four hand-written `cloudflare_dns_record` resources (jack/john/auth/gluck)
were migrated into the keyed `site` resource with `moved {}` blocks — the
apply was **0 added, 0 destroyed, 5 changed** (comment refresh + ingress
reorder only; tunnel identity and all routing untouched), and a re-plan is
clean. `hostnames.auto.tfvars.json` is committed as a snapshot so Terraform
runs standalone; it's regenerated, not hand-edited.
