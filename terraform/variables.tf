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

# ── inbound mail via addy.io ─────────────────────────────────────────

variable "addy_inbound_enabled" {
  type        = bool
  default     = false
  description = "Publish the addy.io apex MX records so the domain can receive mail."
}

variable "addy_sending_enabled" {
  type        = bool
  default     = false
  description = "Publish the apex SPF and both DKIM CNAMEs so aliases can send and reply."
}

variable "addy_verify_token" {
  type        = string
  default     = ""
  description = <<-EOT
    The aa-verify value addy.io shows in its Check DNS records dialog. Unique
    per domain add, so it cannot be derived or reused. Empty publishes no
    ownership record.
  EOT
}

variable "addy_mx_hosts" {
  type = map(string)
  default = {
    "10" = "mail.anonaddy.me"
    "20" = "mail2.anonaddy.me"
  }
  description = "addy.io inbound mail exchangers, keyed by priority."
}

variable "addy_spf_qualifier" {
  type        = string
  default     = "~all"
  description = <<-EOT
    Trailing qualifier on the apex SPF record. addy.io documents -all. This
    defaults to ~all because a hard fail at the apex silently discards mail
    from any sender not yet accounted for. Flip to -all once alignment is
    confirmed in DMARC reports.
  EOT
}
