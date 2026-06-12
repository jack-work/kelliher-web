terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.8.2"
    }
  }
  required_version = ">= 1.2"
}

provider "cloudflare" {
  api_token = trimspace(file(pathexpand(var.cloudflare_token_file)))
}

# ─── Tunnel ─────────────────────────────────────────────────────────

resource "cloudflare_zero_trust_tunnel_cloudflared" "kelliher_web" {
  account_id = var.cloudflare_account_id
  name       = "kelliher-web"
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "kelliher_web" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.kelliher_web.id
}

# ─── DNS + ingress, derived from the kelliher-web sites contract ─────
#
# Everything below is driven by var.hostnames, which comes from
# hostnames.auto.tfvars.json — generated from the evaluated NixOS config
# (services.kelliher-web.sites.*.hostnames). A site "configures itself":
# declaring a hostname in its Nix module is all that's needed to get a
# proxied CNAME and a tunnel-ingress rule here. No per-site Terraform.

resource "cloudflare_dns_record" "site" {
  for_each = toset(var.hostnames)

  zone_id = var.cloudflare_zone_id
  name    = each.key
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kelliher_web.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "${each.key} — managed by OpenTofu (from kelliher-web sites)"
}

# Migrate the previously hand-written records into the keyed resource so
# the refactor moves state instead of destroying/recreating DNS.
moved {
  from = cloudflare_dns_record.jack
  to   = cloudflare_dns_record.site["jack.kelliher.info"]
}
moved {
  from = cloudflare_dns_record.john
  to   = cloudflare_dns_record.site["john.kelliher.info"]
}
moved {
  from = cloudflare_dns_record.auth
  to   = cloudflare_dns_record.site["auth.kelliher.info"]
}
moved {
  from = cloudflare_dns_record.gluck
  to   = cloudflare_dns_record.site["gluck.kelliher.info"]
}

# ─── Tunnel ingress config ──────────────────────────────────────────

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "kelliher_web" {
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.kelliher_web.id
  account_id = var.cloudflare_account_id
  config = {
    ingress = concat(
      [for h in var.hostnames : {
        hostname = h
        service  = var.tunnel_service
      }],
      [{ service = "http_status:404" }],
    )
  }
}

# ─── Outputs ────────────────────────────────────────────────────────

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.kelliher_web.id
}

output "tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.kelliher_web.token
  sensitive = true
}
