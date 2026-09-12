---
name: secret-delivery
description: How secrets reach processes on this platform, and the three ways not to deliver them. Read before wiring a credential into any unit, or when reviewing one.
---

# Delivering a secret to a unit

## The order of preference

| method | who can read it | use when |
|---|---|---|
| **a file path the program opens** (`--token-file`, `*_file` config keys, `$CREDENTIALS_DIRECTORY/x`) | the file's owner | always, if the program supports it |
| **the process environment** | root, and the process's own uid, via `/proc/<pid>/environ` mode 0400 | the program only accepts an env var |
| **argv** | **every account on the machine** | never |

`LoadCredential` puts the value in a per-unit tmpfs at mode 0400 and removes it
when the unit stops, with no dependency on activation-time chown ordering. It is
the best form of the first row. A sops path with `owner` set is the second best
and is what the tunnel uses.

## Why argv is disqualifying

`/proc/<pid>/cmdline` is mode `-r--r--r--`. Not owner-readable: **world**-readable.
`/proc` on spain is mounted without `hidepid`, so every local account can read
every other process's arguments, including the `DynamicUser` identities of every
service on the box.

This is not theoretical. On 2026-09-12 the Cloudflare tunnel token was being
passed as `--token "$TOKEN"`, and it was recovered from `/proc/<pid>/cmdline` as
an ordinary login user with no `sudo`. The tunnel is the ingress for every
hostname on the estate, so that one secret is worth more than any per-service
credential. It was delivered correctly from sops and then handed to argv anyway,
which is the shape to watch for: the careful part and the careless part in the
same three lines.

`cloudflared` supports `--token-file`, so the fix removed argv entirely rather
than moving the token to the environment.

## The trap when avoiding argv

Reaching for the environment is the usual instinct and it is a real improvement,
but do not reach for a unit-file literal on the way:

```nix
Environment = "TOKEN=..."   # NEVER
```

Unit files are rendered into `/nix/store`, which is world-readable, permanent,
and in the flake's git history. That is worse than argv, because argv at least
dies with the process.

## Checking a unit

```sh
tr '\0' ' ' < /proc/$(pgrep -f <name>)/cmdline
```

If a secret appears, it is readable by everyone on the box.
