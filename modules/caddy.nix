# kelliher-web — Caddy reverse proxy: the site contract, Caddyfile
# generation, computed hostname views, and the Caddy systemd unit.
#
# The security-critical Remote-* header handling lives here (see the long
# comment above `stripSnippet`): every site block strips client-supplied
# Remote-* headers unconditionally; `requireAuth` layers forward_auth on top.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.kelliher-web;
  hardenedServiceConfig = import ../lib/hardened.nix;

  siteSubmodule = lib.types.submodule {
    options = {
      hostnames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Fully-qualified hostnames for this site. Unioned with
          the expansion of `subdomains × baseDomains` at the
          platform level. Use this when a name doesn't fit the
          base domains - apex records, a legacy zone, a
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
        description = "Port to reverse proxy to, on `proxyHost`";
      };

      proxyHost = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        example = "100.92.208.109";
        description = ''
          Host to reverse proxy to. Defaults to localhost, which is the
          shape every service on this platform should prefer: a backend
          bound to loopback can only be reached through Caddy, so the
          forward-auth gate is not merely the front door but the only one.

          Set this only when the upstream genuinely cannot live on spain --
          the first case was prangl2's callboard, which reads a figaro
          store that exists on another machine. An off-host upstream is
          reachable by anything that can route to it, so the app itself
          MUST then check the Remote-Groups header Authelia stamps.
          Caddy strips client-supplied Remote-* before the auth subrequest,
          so that check is meaningful; without it, the tailnet is the
          security boundary and Authelia is decoration.
        '';
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

      bearerBypass = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let requests carrying `Authorization: Bearer …` skip
          forward_auth and reach the backend directly, so an API
          client holding an OIDC access token from Authelia can
          call this site without a browser session.

          Setting this is an ASSERTION ABOUT THE BACKEND: "this
          app verifies the JWT itself, against Authelia's JWKS,
          before doing anything." If that is not true, this option
          is not a bypass to a stricter check — it is an open door,
          because the header only has to be SHAPED like a bearer
          token to take it. It does not have to be valid. It does
          not have to be a JWT.

          Default false, and the default is the whole point. This
          used to be unconditional, which made `requireAuth = true`
          silently mean "Authelia gates this, unless the caller
          says the magic word, in which case your backend had
          better be checking" — an obligation invisible at the call
          site. Three sites had inherited it without a verifier:
          gluck-files (a file_server with no backend process at
          all), keel (git hosting; its OIDC work is unmerged), and
          the Element client. All three answered 200 to
          `Authorization: Bearer not-a-real-token` in production.

          Before setting this true, test it rather than assume it.
          Curl the site with a garbage bearer token: 401 means the
          backend verifies and rejects, 200 means it never looked.
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
      site.hostnames ++ lib.concatMap (base: map (sub: "${sub}.${base}") site.subdomains) cfg.baseDomains
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
  #
  # THAT EXPECTATION IS NOW OPT-IN (`bearerBypass`), because it was
  # being extended to backends that had never agreed to it. A site
  # inherits Authelia by asking for `requireAuth`; it should not
  # also inherit an obligation to verify JWTs that nothing in the
  # call site mentions. When the backend does not hold up its end,
  # the composition is not "authenticated site" but "open site with
  # extra steps": the header only has to LOOK like a bearer token.
  #
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
  authSnippet =
    site:
    let
      # With the bypass, forward_auth runs only for requests that do
      # not look like API calls. Without it, forward_auth runs for
      # everything, which is what `requireAuth` reads like.
      matcher = lib.optionalString site.bearerBypass "@no_bearer ";
    in
    ''
      ${lib.optionalString site.bearerBypass "@no_bearer not header Authorization Bearer*"}
      forward_auth ${matcher}${cfg.forwardAuthAddress} {
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
          "reverse_proxy ${site.proxyHost}:${toString site.proxyTo}";
    in
    ''
      ${hostMatcher}
      handle @${matcherName} {
        route {
          ${stripSnippet}
          ${lib.optionalString site.requireAuth (authSnippet site)}
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
in
{
  options.services.kelliher-web = {
    sites = lib.mkOption {
      type = lib.types.attrsOf siteSubmodule;
      default = { };
      description = "Sites to host via Caddy";
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
        lib.concatMap effectiveHostnames (lib.filter (s: s.requireAuth) (lib.attrValues cfg.sites))
      )
    );

    services.kelliher-web.allRequiredGroups = lib.sort (a: b: a < b) (
      lib.unique (lib.concatMap (s: s.requiredGroups) (lib.attrValues cfg.sites))
    );

    # Fail loud at eval time if a site declares neither a
    # fully-qualified hostname nor a subdomain: it would produce
    # an empty `host` matcher and match nothing, which is worse
    # than a build break.
    assertions =
      lib.mapAttrsToList (name: site: {
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
      ++ lib.mapAttrsToList (name: site: {
        # bearerBypass without requireAuth emits nothing at all: there is
        # no forward_auth for a bearer request to skip. Silently ignoring
        # it would let a site read as if it had an authenticated API path
        # when it is simply public, which is the kind of comfortable
        # misreading this option exists to end.
        assertion = site.bearerBypass -> site.requireAuth;
        message =
          "kelliher-web: site '${name}' sets `bearerBypass` without `requireAuth`; "
          + "there is no forward_auth to bypass, so the site is public and the "
          + "option is decoration. Drop it, or add requireAuth.";
      }) cfg.sites
      ++ lib.mapAttrsToList (name: site: {
        # A static tree cannot verify a JWT: there is no process to do it.
        # This is the exact composition that left files.kelliher.info
        # readable by anything that sent a bearer-shaped header.
        assertion = site.bearerBypass -> (site.root == null && site.rootPath == null);
        message =
          "kelliher-web: site '${name}' sets `bearerBypass` but serves files directly "
          + "(root/rootPath). `bearerBypass` asserts that a BACKEND verifies the JWT, "
          + "and a file_server has no backend to do it — this is how gluck-files came "
          + "to answer 200 to 'Authorization: Bearer not-a-real-token'.";
      }) cfg.sites
      ++ lib.mapAttrsToList (name: site: {
        # An off-host upstream is reachable by anything that can route to it, so
        # the loopback bind is no longer doing the work the trust model assumes.
        # Requiring forward-auth does not make the backend unreachable -- only
        # the backend's own Remote-Groups check can do that -- but shipping one
        # of these WITHOUT the auth gate would put an unauthenticated service on
        # the public internet, which is worth failing the build over.
        assertion = site.proxyHost == "localhost" || site.proxyTo == null || site.requireAuth;
        message =
          "kelliher-web: site '${name}' proxies off-host to ${site.proxyHost} without requireAuth. "
          + "A loopback upstream is protected by being unreachable; an off-host one is not. "
          + "Set requireAuth = true, and make the backend check Remote-Groups itself.";
      }) cfg.sites;

    systemd.services = {
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
    };
  };
}
