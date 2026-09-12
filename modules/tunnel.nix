# kelliher-web — Cloudflare tunnel: the cloudflared systemd unit and its
# dedicated (static) service user. Ingress terminates at Cloudflare and is
# tunnelled to the local Caddy; this unit just runs `cloudflared tunnel run`
# with the token from `services.kelliher-web.tunnelTokenFile`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.kelliher-web;
  hardenedServiceConfig = import ../lib/hardened.nix;
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = {
      kelliher-web-cloudflared = {
        description = "kelliher-web — Cloudflare Tunnel";
        after = [
          "network-online.target"
          "kelliher-web-caddy.service"
        ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        script = ''
          exec ${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run \
            --token-file ${cfg.tunnelTokenFile}
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

    users.users.kelliher-web-tunnel = {
      isSystemUser = true;
      group = "kelliher-web-tunnel";
    };
    users.groups.kelliher-web-tunnel = { };
    users.groups.kelliher-web-tunnel = { };
  };
}
