variable "cloudflare_zone_id" {
  description = "Zone ID for kelliher.info (found in Cloudflare dashboard)"
  type        = string
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
