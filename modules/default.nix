# kelliher-web NixOS module — aggregator.
#
# The platform is split by concern; NixOS merges the `options`, `config`,
# `assertions` and `systemd.services` each submodule contributes. Import
# this single file (it is `nixosModules.default`) and every concern comes
# along:
#
#   platform.nix — core knobs (enable, port, tunnelTokenFile, forwardAuth,
#                  baseDomains).
#   caddy.nix    — the site contract, Caddyfile generation, computed
#                  hostname views, and the Caddy unit.
#   storage.nix  — per-service storage volumes (plain / ZFS backends).
#   tunnel.nix   — the Cloudflare tunnel unit + its service user.
{
  imports = [
    ./platform.nix
    ./caddy.nix
    ./storage.nix
    ./tunnel.nix
  ];
}
