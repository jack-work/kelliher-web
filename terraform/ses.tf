# ─────────────────────────────────────────────────────────────────────
# Outbound mail for the estate: Amazon SES, with its DNS published here.
# ─────────────────────────────────────────────────────────────────────
#
# Authelia sends two things to humans: the one-time code that gates 2FA
# enrolment, and password reset. Before this they were written to a file on
# spain, which made the operator the delivery mechanism for his own family's
# logins and the only password-reset path.
#
# Why this file is in the same Terraform state as the Cloudflare config, rather
# than a separate thing: SES mints the DKIM tokens and Cloudflare must publish
# them. Keeping both providers in one apply means the tokens are WIRED, not
# copied by hand. There is no step where somebody pastes three records and gets
# one of them subtly wrong.
#
# spain never sends mail itself. A residential IP has no sending reputation and
# is refused by every large provider.

provider "aws" {
  region = var.ses_region
}

# ── the identity ─────────────────────────────────────────────────────
# EasyDKIM: SES generates the keypair and we publish three CNAMEs pointing at
# its published public halves. We never hold a signing key.
resource "aws_sesv2_email_identity" "estate" {
  email_identity = var.mail_domain

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

# ── DKIM, wired rather than pasted ───────────────────────────────────
# MUST be proxied = false. An orange-clouded CNAME returns Cloudflare's own
# answer, the DKIM lookup fails, and every message is unsigned. The site
# records in main.tf are proxied; these are deliberately not.
resource "cloudflare_dns_record" "ses_dkim" {
  count = 3

  zone_id = local.zones[var.mail_domain]
  name    = "${aws_sesv2_email_identity.estate.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.mail_domain}"
  content = "${aws_sesv2_email_identity.estate.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"
  type    = "CNAME"
  ttl     = 3600
  proxied = false
  comment = "SES DKIM ${count.index + 1}/3 — managed by OpenTofu"
}

# ── custom MAIL FROM, on a subdomain ─────────────────────────────────
# Deliberately a subdomain. SPF has to authorise the envelope sender's domain,
# and putting `include:amazonses.com` on the apex would mean editing the apex
# SPF record. The apex has no SPF today and this keeps it that way, so adding
# a different mail provider later cannot collide with this one.
#
# Without this, SES uses amazonses.com as the envelope sender, SPF does not
# align with the From header, and DMARC alignment rests on DKIM alone.
resource "aws_sesv2_email_identity_mail_from_attributes" "estate" {
  email_identity         = aws_sesv2_email_identity.estate.email_identity
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
  mail_from_domain       = "${var.mail_from_subdomain}.${var.mail_domain}"
}

resource "cloudflare_dns_record" "ses_mail_from_mx" {
  zone_id  = local.zones[var.mail_domain]
  name     = "${var.mail_from_subdomain}.${var.mail_domain}"
  content  = "feedback-smtp.${var.ses_region}.amazonses.com"
  type     = "MX"
  priority = 10
  ttl      = 3600
  comment  = "SES custom MAIL FROM — bounce feedback"
}

resource "cloudflare_dns_record" "ses_mail_from_spf" {
  zone_id = local.zones[var.mail_domain]
  name    = "${var.mail_from_subdomain}.${var.mail_domain}"
  content = "\"v=spf1 include:amazonses.com ~all\""
  type    = "TXT"
  ttl     = 3600
  comment = "SPF for the SES envelope sender"
}

# ── DMARC ────────────────────────────────────────────────────────────
# p=none to start: it reports without rejecting. Tightening to quarantine or
# reject before the reports show alignment is how a domain silently stops
# delivering its own mail.
resource "cloudflare_dns_record" "dmarc" {
  zone_id = local.zones[var.mail_domain]
  name    = "_dmarc.${var.mail_domain}"
  content = "\"v=DMARC1; p=none; rua=mailto:${var.dmarc_report_address}; fo=1\""
  type    = "TXT"
  ttl     = 3600
  comment = "DMARC, observe-only — managed by OpenTofu"
}

# ── the SMTP user ────────────────────────────────────────────────────
# Scoped to sending, and to this identity only. An SES SMTP credential is an
# IAM access key whose secret is run through a documented transform; the
# provider exposes the result as ses_smtp_password_v4.
#
# NOTE: that password lands in Terraform state. State already holds the
# Cloudflare tunnel token, so it is a secret store either way and is mode 0600
# and gitignored. If you would rather it stayed out, remove the access_key
# resource and mint the key in the console instead.
resource "aws_iam_user" "ses_smtp" {
  name = "authelia-ses-smtp"
  path = "/service/"
  tags = { purpose = "Authelia outbound mail for ${var.mail_domain}" }
}

resource "aws_iam_user_policy" "ses_smtp" {
  name = "send-as-estate"
  user = aws_iam_user.ses_smtp.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendRawEmail", "ses:SendEmail"]
      Resource = aws_sesv2_email_identity.estate.arn
    }]
  })
}

resource "aws_iam_access_key" "ses_smtp" {
  user = aws_iam_user.ses_smtp.name
}

output "ses_smtp_username" {
  value       = aws_iam_access_key.ses_smtp.id
  description = "Put this in identity.nix as smtpUsername."
}

output "ses_smtp_password" {
  value       = aws_iam_access_key.ses_smtp.ses_smtp_password_v4
  sensitive   = true
  description = "Read once with `tofu output -raw ses_smtp_password`, then put it in sops as authelia_smtp_password."
}

output "ses_smtp_host" {
  value       = "email-smtp.${var.ses_region}.amazonaws.com"
  description = "Put this in identity.nix as smtpAddress, as smtp://<host>:587."
}
