---
name: inbound-mail
description: How kelliher.info receives mail through addy.io, what it may not disturb in the SES outbound path, and the measurements that proved the two are independent. Verified 2026-10-09 23:0x EDT. Owner b8765aea, El Cartero.
---

# Inbound mail

The estate could send mail and not receive it. SES carries outbound, declared in
`terraform/ses.tf`. Inbound arrives through addy.io, an alias forwarder: mail to
an alias at the domain is relayed to a real inbox, so no mailbox has to be hosted.

Nothing here is applied. Both toggles in `terraform/addy.tf` default to off.

## The records

| name | type | value | needed for |
|---|---|---|---|
| apex | TXT | `aa-verify=<token>` | ownership, removable once verified |
| apex | MX 10 | `mail.anonaddy.me` | receiving |
| apex | MX 20 | `mail2.anonaddy.me` | receiving |
| apex | TXT | `v=spf1 include:spf.anonaddy.me <qualifier>` | sending as an alias |
| `dk1._domainkey` | CNAME | `dk1._domainkey.anonaddy.me` | sending as an alias |
| `dk2._domainkey` | CNAME | `dk2._domainkey.anonaddy.me` | sending as an alias |

Receiving needs the two MX records alone, so `addy_inbound_enabled` and
`addy_sending_enabled` are separate. None of these may be proxied: addy.io
reports that an orange-clouded record breaks its verification.

The `aa-verify` token is unique to each domain add and is shown only in
addy.io's dialog. It cannot be derived, so `addy_verify_token` has no default.

## A paid plan is required

addy.io's documentation states that free accounts cannot add domains. Read
2026-10-09: Lite is $1/month billed yearly and allows one custom domain; Pro is
$3/month yearly, $4 monthly, and allows twenty.

## Why this does not disturb SES

`ses.tf` already recorded the intent: SES uses a custom MAIL FROM on the `mail`
subdomain specifically so the apex SPF record stays free for another provider.
This change spends that reservation.

Confirmed from a delivered message rather than from the design, 2026-10-09:

| header | value | consequence |
|---|---|---|
| `Return-Path` | `…@mail.kelliher.info` | SPF is evaluated against the subdomain, never the apex |
| `Received-SPF` | `pass` for `mail.kelliher.info` | unaffected by an apex SPF record |
| `DKIM-Signature` | `d=kelliher.info`, selector `wlq6fm4y…` | DMARC passes on DKIM alignment alone |

Selector collision was checked against the live zone the same day, not inferred:
SES publishes three CNAMEs under random 32-character selectors, addy.io wants
`dk1` and `dk2`. No overlap. The zone held 28 records and no apex MX and no apex
SPF, so both are created rather than edited.

## Two consequences worth deciding before applying

**The apex becomes a receiving domain.** Authelia sends as `auth@kelliher.info`.
Once the apex MX points at addy.io, replies and bounces to that address flow to
addy.io, and catch-all would forward them onward. That is a change in behaviour
for live mail, not only a new capability.

**`-all` is a hard fail.** addy.io documents it. `addy_spf_qualifier` defaults to
`~all` because a hard fail at the apex discards mail from any sender not yet
accounted for, and nothing has yet proved that no such sender exists. Flip it
once DMARC reports show alignment.

## DMARC stays at p=none

addy.io's dialog asks for `p=quarantine; adkim=s`. `ses.tf` already argues the
other way, and that argument holds: tightening before the reports show alignment
is how a domain stops delivering its own mail. The record is terraform-managed in
`ses.tf`, so changing it is an edit to the outbound path, not an addition to this
one. Out of scope here.

## Negative control

The claim that the defaults publish nothing was tested rather than asserted, by
evaluating the count and `for_each` expressions in all four states:

| state | records produced |
|---|---|
| defaults | none |
| `addy_inbound_enabled` | 2 MX, priorities 10 and 20 |
| `addy_sending_enabled` | 1 SPF, 2 DKIM |
| `addy_verify_token` set | 1 TXT |

## Applying

One apply at a time, estate-wide: the Garage state backend has no lock, proven
in `terraform/backend.tf`. The backend is loopback only, so an apply from the
workstation needs `ssh -N -L 3900:127.0.0.1:3900 spain@spain` first.

Cloudflare DNS edit permission for the token is unverified as of 2026-10-09. The
same token is known to lack Cache Rules edit. If an apply returns 403, that is a
token scope to widen, not a reason to edit records by hand: a hand-made record
drifts from state and the next apply can destroy it.

Verify from outside afterwards, against `1.1.1.1` rather than spain's own
resolver, then prove delivery by sending to a real alias. A record that resolves
is not a delivered message.
