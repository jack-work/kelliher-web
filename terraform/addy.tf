# ─── Inbound mail: addy.io ───────────────────────────────────────────
#
# Reasoning, measurements and the verification record: docs/inbound-mail.md.
#
# Both toggles default OFF, so applying this file changes nothing until a
# variable is set deliberately. Receiving needs only the two MX records;
# sending as an alias additionally needs SPF and both DKIM CNAMEs.

resource "cloudflare_dns_record" "addy_verify" {
  count = var.addy_verify_token == "" ? 0 : 1

  zone_id = local.zones[var.mail_domain]
  name    = var.mail_domain
  content = "\"aa-verify=${var.addy_verify_token}\""
  type    = "TXT"
  ttl     = 3600
  comment = "addy.io domain ownership — removable once verified"
}

resource "cloudflare_dns_record" "addy_mx" {
  for_each = var.addy_inbound_enabled ? var.addy_mx_hosts : {}

  zone_id  = local.zones[var.mail_domain]
  name     = var.mail_domain
  content  = each.value
  type     = "MX"
  priority = tonumber(each.key)
  ttl      = 3600
  comment  = "addy.io inbound, priority ${each.key} — managed by OpenTofu"
}

resource "cloudflare_dns_record" "addy_spf" {
  count = var.addy_sending_enabled ? 1 : 0

  zone_id = local.zones[var.mail_domain]
  name    = var.mail_domain
  content = "\"v=spf1 include:spf.anonaddy.me ${var.addy_spf_qualifier}\""
  type    = "TXT"
  ttl     = 3600
  comment = "SPF for sending as an addy.io alias"
}

resource "cloudflare_dns_record" "addy_dkim" {
  for_each = var.addy_sending_enabled ? toset(["dk1", "dk2"]) : toset([])

  zone_id = local.zones[var.mail_domain]
  name    = "${each.key}._domainkey.${var.mail_domain}"
  content = "${each.key}._domainkey.anonaddy.me"
  type    = "CNAME"
  ttl     = 3600
  proxied = false
  comment = "addy.io DKIM ${each.key} — managed by OpenTofu"
}

check "apex_spf_is_not_claimed_twice" {
  assert {
    condition     = !(var.addy_sending_enabled && var.mail_from_subdomain == "")
    error_message = "SES would send with an apex envelope while addy.io owns the apex SPF record. Keep SES on a MAIL FROM subdomain."
  }
}
