# Third-party notices

Redoubt wires together software written by other people. The kit does
not modify any of it: it downloads each program from its authors and
runs it as is. Every piece keeps its own license, listed here so you
can read exactly what the kit installs.

## Mesh

- NetBird client and agent: BSD-3-Clause
- NetBird management, signal and relay server: GNU AGPL-3.0
  https://github.com/netbirdio/netbird

## Apps

- Nextcloud: GNU AGPL-3.0
  https://github.com/nextcloud/server
- Immich: GNU AGPL-3.0
  https://github.com/immich-app/immich
- SearXNG: GNU AGPL-3.0
  https://github.com/searxng/searxng
- Homarr (dashboard panel): Apache-2.0
  https://github.com/homarr-labs/homarr
- Dockge (container dashboard): MIT
  https://github.com/louislam/dockge
- Pi-hole (ad and tracker blocking): EUPL-1.2
  https://github.com/pi-hole/pi-hole
- Hagezi DNS blocklists (the ad shield's lists): GPL-3.0
  https://github.com/hagezi/dns-blocklists
- Unbound (DNS resolver): BSD-3-Clause upstream, MIT container image
  https://github.com/NLnetLabs/unbound
  https://github.com/klutchell/unbound
- Caddy (web server and certificates): Apache-2.0
  https://github.com/caddyserver/caddy
- Glances (system monitor): LGPL-3.0
  https://github.com/nicolargo/glances
- Redis (cache and queues): BSD-3-Clause
  https://github.com/redis/redis
- PostgreSQL (database): PostgreSQL License
  https://github.com/postgres/postgres

## Encrypted vault

- fscrypt (the ext4/f2fs kernel motor): Apache-2.0
  https://github.com/google/fscrypt
- gocryptfs (the btrfs/xfs fuse motor): MIT
  https://github.com/rfjakob/gocryptfs

## Brain

- llama.cpp (the local model engine): MIT
  https://github.com/ggml-org/llama.cpp
- Qwen (the model weights): Apache-2.0
  https://github.com/QwenLM/Qwen3

## System

- Docker Engine (container runtime): Apache-2.0
  https://github.com/moby/moby
- NVIDIA Container Toolkit (gpu offload, when a card is present): Apache-2.0
  https://github.com/NVIDIA/nvidia-container-toolkit
- Trivy (the security scanner that audits the stack): Apache-2.0
  https://github.com/aquasecurity/trivy
- Hermes Agent (the on-box agent): MIT
  https://github.com/NousResearch/hermes-agent
- gum (terminal interface): MIT
  https://github.com/charmbracelet/gum

## Icons

The icons folder ships the panel's app icons. Their sources and
licenses (Apache-2.0, CC-BY-4.0 and GPL-3.0, per project) are
listed in icons/ATTRIBUTION.md, next to the files themselves.
The Papirus set (PapirusDevelopmentTeam/papirus_icons, GPL-3.0)
rides as a channel tarball and is served to the panel tiles by
the local edge under the same upstream path.

## License texts

The full texts of the GNU AGPLv3, GPL-3.0, Apache-2.0, MIT and
BSD-3-Clause licenses are published by their authors at the links
above and by the license stewards at:

  https://www.gnu.org/licenses/agpl-3.0.html
  https://www.gnu.org/licenses/gpl-3.0.html
  https://www.apache.org/licenses/LICENSE-2.0
  https://opensource.org/license/mit
  https://opensource.org/license/bsd-3-clause
