# kelliher-web dev shell — tooling for driving the Terraform side of the
# platform (opentofu) plus the sops/age secret workflow. Entered via
# `nix develop`. Kept separate from the NixOS module (./modules) since it's
# host-agnostic and has nothing to do with what runs on spain.
{ pkgs }:
pkgs.mkShell {
  name = "kelliher-web";
  buildInputs = with pkgs; [
    opentofu
    sops
    age
    ssh-to-age
    jq
    curl
    git
  ];
  shellHook = ''
    echo ""
    echo "kelliher-web"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  cd terraform/   Manage infra"
    echo ""
  '';
}
