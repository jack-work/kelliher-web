# ─────────────────────────────────────────────────────────────────────
# State lives in Garage on spain, not on a laptop and not in AWS.
# ─────────────────────────────────────────────────────────────────────
#
# Garage is S3-compatible, so the s3 backend works against it with path-style
# addressing and the AWS-specific preflight checks switched off. Keeping state
# here means either machine can apply, state stops living in a file on one
# laptop, and no new cloud dependency is added to hold it.
#
# Credentials for the BACKEND are Garage's, not AWS's, and they are deliberately
# a different profile from the one the aws provider uses: the backend talks to
# spain, the provider talks to Amazon, and they must not share a key.
#
# NO LOCKING. Measured, not assumed:
#   - a conditional PUT (If-None-Match: *) succeeds twice against Garage 1.3.1,
#     where S3 returns 412, so a lock cannot be acquired atomically
#   - a hand-planted .tflock object did NOT stop an apply
#   - put-bucket-versioning returns NotImplemented, so there is no version
#     history to recover a clobbered state from
# `use_lockfile` is therefore left OFF rather than set to something that implies
# a protection it does not provide. ONE APPLY AT A TIME. The safety net is the
# copy OpenTofu keeps locally plus whatever you took before migrating.
terraform {
  backend "s3" {
    bucket = "tfstate"
    key    = "kelliher-web/terraform.tfstate"
    region = "spain"

    endpoints      = { s3 = "http://127.0.0.1:3900" }
    use_path_style = true

    # Garage is not AWS: there is no STS, no account id, no AWS region to
    # validate, and its checksum handling differs.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true

    profile                  = "garage"
    shared_credentials_files = ["/home/gluck/.config/kelliher-web/garage-credentials"]
  }
}

# ── reaching the backend ──────────────────────────────────────────────
# The endpoint is LOOPBACK, not s3.kelliher.info, and that is deliberate.
#
# Through the public hostname, aws-sdk-go-v2 fails SigV4 with
# "Forbidden: Invalid signature". Measured: awscli signs the same request to the
# same endpoint with the same key and succeeds, so the key and the grant are
# fine. The difference is which headers each SDK signs; Cloudflare rewrites one
# of them in flight. The state file also has no business crossing the public
# internet, since it holds the tunnel token.
#
# So the backend is reachable from exactly two places:
#
#   on spain      directly, Garage binds 127.0.0.1:3900
#   on a laptop   through a tunnel, which the gluck-files README already
#                 documents as the way around Cloudflare for S3:
#
#     ssh -N -L 3900:127.0.0.1:3900 spain@spain &
#
# Without one of those, init and plan fail to connect. That is the intended
# behaviour rather than a gap: there is no public path to the state.
