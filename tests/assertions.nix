{
  pkgs,
  lib,
  nixosSystem,
}:
let
  evalSite =
    site:
    (nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        ../modules
        {
          services.kelliher-web = {
            enable = true;
            baseDomains = [ "example.test" ];
            tunnelTokenFile = "/dev/null";
            sites.subject = site;
          };
        }
      ];
    }).config;

  failures = site: map (a: a.message) (lib.filter (a: !a.assertion) (evalSite site).assertions);

  mentions = site: lib.filter (m: lib.hasInfix "trustsRemoteHeaders" m) (failures site);

  portero = {
    subdomains = [ "portero" ];
    proxyTo = 9101;
    requireAuth = true;
    trustsRemoteHeaders = true;
  };

  cases = {
    # The shape portero's mint half ships: gated, loopback, header-trusting.
    accepted = {
      want = [ ];
      got = mentions portero;
    };

    ungated = {
      want = [ "requireAuth" ];
      got = mentions (portero // { requireAuth = false; });
    };

    bearer = {
      want = [ "bearerBypass" ];
      got = mentions (portero // { bearerBypass = true; });
    };

    offHost = {
      want = [ "off-host" ];
      got = mentions (portero // { proxyHost = "100.92.208.109"; });
    };

    # The control for the rendered-text half: a site that does not claim the
    # trust gets no complaint, so a failure above is about the claim and not
    # about every site on the platform.
    unclaimed = {
      want = [ ];
      got = mentions (removeAttrs portero [ "trustsRemoteHeaders" ]);
    };
  };

  report = lib.mapAttrsToList (
    name:
    { want, got }:
    let
      ok =
        if want == [ ] then
          got == [ ]
        else
          lib.length got >= 1 && lib.all (needle: lib.any (m: lib.hasInfix needle m) got) want;
    in
    "${if ok then "ok" else "FAIL"} ${name}: ${toString (lib.length got)} assertion(s) fired"
  ) cases;
in
pkgs.runCommand "kelliher-web-assertions" { } ''
  set -o pipefail
  cat > $out <<'REPORT'
  ${lib.concatStringsSep "\n" report}
  REPORT
  cat $out
  if grep -q FAIL $out; then
    echo "an assertion case did not behave as specified" >&2
    exit 1
  fi
''
