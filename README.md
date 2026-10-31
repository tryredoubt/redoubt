# 🏯 Redoubt: the dojo kit

![platform](https://img.shields.io/badge/platform-Linux-34d399) ![install](https://img.shields.io/badge/install-one_command-34d399) ![telemetry](https://img.shields.io/badge/telemetry-none-34d399) ![stack](https://img.shields.io/badge/stack-open_source-34d399)

A private cloud on your own machine: photos, files, your own search, a
self-hosted mesh and an HTTPS edge with your own certificate authority.
One command to install, zero subscriptions, no telemetry.

```bash
curl -fsSL https://install.tryredoubt.com/redoubt.sh | bash
```

## The promise 🗝️

- 📸 Your photos and files never leave your four walls. No cloud copy,
  no account, no profile for anyone to buy or breach.
- 🔍 Your own search engine (SearXNG). No profile, no auction of your
  questions.
- 🛡️ Ads and trackers dead at the network door (pi-hole), for every
  device in the house.
- 🔐 Encrypted DNS lookups (Unbound + Quad9) and your own encrypted mesh
  (NetBird) to reach home from anywhere.
- 🏠 One old machine, about one hour, and the cloud is yours.

## What's inside 📦

The kit wires together, on purpose:

immich · nextcloud · searxng · netbird · caddy · docker · unbound ·
homarr · pi-hole · glances · redis · postgres

All free. All open source. All linked on the website so you can read
the whole truth.

## Trust, twice 🔒

The installer verifies its bundle twice before running anything: sha256
plus an ed25519 release signature. The private release key never leaves
the build machine; the public half is embedded in the wrapper.

## Supported 📋

Debian/Ubuntu, Arch, Fedora and openSUSE families.

## Built by Naruto 🥷

The dojo kit. One command, and the data comes home.
