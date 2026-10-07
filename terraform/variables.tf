variable "cloudflare_zone_id" {
  description = <<-EOT
    Zone ID for kelliher.info. Legacy single-zone knob, kept so existing
    tfvars keep working; it is folded into `cloudflare_zones` as the
    "kelliher.info" entry. New zones go in `cloudflare_zones`.
  EOT
  type        = string
}

variable "cloudflare_zones" {
  description = <<-EOT
    Additional zones this platform serves, as zone apex -> Cloudflare zone
    ID (e.g. { "figar.org" = "8f93…" }). Every hostname in `hostnames` is
    matched to exactly one zone by apex/suffix, so a site can live on any
    zone listed here without per-site Terraform.
  EOT
  type        = map(string)
  default     = {}
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
  sensitive   = true
}

variable "cloudflare_token_file" {
  description = "Path to file containing Cloudflare API token"
  type        = string
  default     = "~/.secrets/cloudflaretoken"
}

variable "hostnames" {
  description = <<-EOT
    Public hostnames to route through the tunnel. The source of truth is the
    NixOS sites contract (services.kelliher-web.sites.*.hostnames); this list
    is generated into hostnames.auto.tfvars.json by the spain-flake output
    `tunnel-hostnames` and auto-loaded. Do not hand-edit — regenerate instead.
  EOT
  type        = list(string)
  default     = []
}

variable "tunnel_service" {
  description = "Local service the tunnel forwards every hostname to (the shared Caddy)."
  type        = string
  default     = "http://localhost:8780"
}

variable "edge_cached_hostnames" {
  description = <<-EOF2
    Hostnames whose responses Cloudflare may cache, HTML included, for as long
    as the origin's Cache-Control allows. Each must also be in `hostnames`.
    Cloudflare never caches HTML without a rule, so this is opt-in per host.
  EOF2
  type        = list(string)
  default     = []
}

# ── outbound mail (ses.tf) ───────────────────────────────────────────
variable "ses_region" {
  type        = string
  default     = "us-east-1"
  description = "SES region. Also names the bounce-feedback MX and the SMTP host."
}

variable "mail_domain" {
  type        = string
  default     = "kelliher.info"
  description = "Domain mail is sent AS. Must be a zone in var.cloudflare_zones."
}

variable "mail_from_subdomain" {
  type        = string
  default     = "mail"
  description = <<-EOT
    Subdomain used as the SES custom MAIL FROM. A subdomain on purpose: SPF
    authorises the envelope sender's domain, so this keeps the apex SPF record
    free for a different provider later.
  EOT
}

variable "dmarc_report_address" {
  type        = string
  default     = "jackwkelliher@gmail.com"
  description = "Where DMARC aggregate reports go."
}
