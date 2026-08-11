# kelliher-web — core platform options.
#
# The generic hosting platform: this module knows about no specific site.
# Site modules (jack-site, gluck-services, …) register themselves into
# services.kelliher-web.sites and are imported alongside this module by the
# host config. Caddy/site rendering lives in ./caddy.nix, per-service
# storage volumes in ./storage.nix, the Cloudflare tunnel in ./tunnel.nix.
{ lib, ... }:
{
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
  };
}
