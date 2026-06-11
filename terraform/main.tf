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

# ─── DNS ────────────────────────────────────────────────────────────

resource "cloudflare_dns_record" "jack" {
  zone_id = var.cloudflare_zone_id
  name    = "jack"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kelliher_web.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "jack.kelliher.info — managed by OpenTofu"
}

resource "cloudflare_dns_record" "john" {
  zone_id = var.cloudflare_zone_id
  name    = "john"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kelliher_web.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "john.kelliher.info — managed by OpenTofu"
}

resource "cloudflare_dns_record" "auth" {
  zone_id = var.cloudflare_zone_id
  name    = "auth"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kelliher_web.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "auth.kelliher.info (Authelia portal) — managed by OpenTofu"
}

resource "cloudflare_dns_record" "gluck" {
  zone_id = var.cloudflare_zone_id
  name    = "gluck"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.kelliher_web.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
  comment = "gluck.kelliher.info (authenticated API) — managed by OpenTofu"
}

# ─── Tunnel ingress config ──────────────────────────────────────────

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "kelliher_web" {
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.kelliher_web.id
  account_id = var.cloudflare_account_id
  config = {
    ingress = [
      {
        hostname = "jack.kelliher.info"
        service  = "http://localhost:8780"
      },
      {
        hostname = "john.kelliher.info"
        service  = "http://localhost:8780"
      },
      {
        hostname = "auth.kelliher.info"
        service  = "http://localhost:8780"
      },
      {
        hostname = "gluck.kelliher.info"
        service  = "http://localhost:8780"
      },
      {
        service = "http_status:404"
      }
    ]
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
