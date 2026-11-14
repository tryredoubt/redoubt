# Third-party notices

This file lists the third-party software and assets the Redoubt kit
conveys, as wired in kit/redoubt.sh at this release. Each entry records
the version or pin, the source, the copyright holder, the license, and
the notices that license requires.

Entries are marked by conveyance:

- "Redistributed by the kit": the material ships in this repository,
  embedded in kit/redoubt.sh, or on the Redoubt release channel.
- "Downloaded at install time": the kit fetches the material on the
  owner's machine during install or update. The kit does not ship a
  copy of it.

Licenses were checked against each upstream repository and, where a
container image carries metadata, against the image labels.

## Container images

The images below are referenced by the Docker compose stack the kit
writes. Docker pulls them on the owner's machine at install time. The
kit does not redistribute the images.

### Glances (system monitor)

- Image: docker.io/nicolargo/glances:latest, digest
  sha256:a8a1614c2d531f8bd66125050968be3317c093484c82730cc96c83a2df3c732c.
  The pinned digest resolves to v4.5.9 at this release.
- Source: https://github.com/nicolargo/glances
- Copyright: Nicolas Hennion and the Glances contributors
- License: LGPL-3.0. The repository states "distributed under the LGPL
  version 3 license" and ships the text as COPYING.
- License text: https://github.com/nicolargo/glances/blob/develop/COPYING
- Conveyance: downloaded at install time.

### Bulwark (mail filter)

- Image: ghcr.io/bulwark-project/bulwark. This release line pins no
  version and no digest for it; the mail tier stays disabled until the
  release review fills the pins (MAIL_BULWARK_VERSION and
  MAIL_BULWARK_DIGEST are empty in kit/redoubt.sh). The mail tier
  comments reference version 1.18.
- Source: the image is published on the GitHub Container Registry as
  ghcr.io/bulwark-project/bulwark.
- Copyright: the Bulwark project contributors
- License: AGPL-3.0
- License text: https://www.gnu.org/licenses/agpl-3.0.html
- Conveyance: wired but not conveyed at this release (the tier is off).

### llama.cpp (local model engine)

- Images: ghcr.io/ggml-org/llama.cpp:server, :server-vulkan and
  :server-cuda, each pinned by digest in kit/redoubt.sh. The server tag
  resolves to v1.0.0-b12359-b1b770d at the time of writing.
- Source: https://github.com/ggml-org/llama.cpp
- Copyright: Copyright (c) 2023-2026 The ggml authors
- License: MIT
- License text: https://github.com/ggml-org/llama.cpp/blob/master/LICENSE
- Conveyance: downloaded at install time.

### Homarr (dashboard)

- Image: ghcr.io/homarr-labs/homarr:latest (no digest pin at this
  release).
- Source: https://github.com/homarr-labs/homarr
- Copyright: Copyright (c) 2024 Meier Lukas, Thomas Camlong and Homarr
  Labs
- License: Apache-2.0
- License text: https://www.apache.org/licenses/LICENSE-2.0 and
  https://github.com/homarr-labs/homarr/blob/dev/LICENSE
- NOTICE: the upstream repository ships no NOTICE file.
- Conveyance: downloaded at install time.

### Home Assistant

- Image: ghcr.io/home-assistant/home-assistant:2026.10.3 (the
  HA_VERSION pin in kit/redoubt.sh).
- Source: https://github.com/home-assistant/core
- Copyright: the Home Assistant Authors
- License: Apache-2.0
- License text: https://www.apache.org/licenses/LICENSE-2.0 and
  https://github.com/home-assistant/core/blob/dev/LICENSE.md
- NOTICE: the upstream repository ships no NOTICE file.
- Conveyance: downloaded at install time.

### Immich server (photos)

- Image: ghcr.io/immich-app/immich-server:release, digest
  sha256:7c489add298fc2f92cda4c777de6462aa206877e04087b815f62c7664af0b53b.
  The pinned digest resolves to v3.4.1 at this release.
- Source: https://github.com/immich-app/immich
- Copyright: the Immich project contributors
- License: AGPL-3.0
- License text: https://github.com/immich-app/immich/blob/main/LICENSE
- Conveyance: downloaded at install time.

### Immich PostgreSQL (photos database)

- Image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
  (no digest pin at this release).
- Source: https://github.com/immich-app/base-images (the image is built
  and published by the Immich project; its metadata declares AGPL-3.0
  for the image).
- The image builds on PostgreSQL 14 (PostgreSQL License,
  https://www.postgresql.org/about/licence/), pgvector (PostgreSQL
  License, https://github.com/pgvector/pgvector/blob/master/LICENSE),
  VectorChord 0.4.3 (AGPL-3.0, dual licensed with the Elastic License
  2.0, https://github.com/tensorchord/VectorChord/blob/main/LICENSE),
  and pgvectors 0.2.0 from pgvecto.rs (Apache-2.0,
  https://github.com/tensorchord/pgvecto.rs/blob/main/LICENSE).
- Copyright: PostgreSQL Global Development Group for the base; the
  Immich project for the image; the VectorChord and pgvecto.rs authors
  for their extensions.
- License texts: at the links above.
- Conveyance: downloaded at install time.

### Stalwart Mail Server

- Image: ghcr.io/stalwartlabs/mail-server. This release line pins no
  version and no digest for it; the mail tier stays disabled until the
  release review fills the pins (MAIL_STALWART_VERSION and
  MAIL_STALWART_DIGEST are empty in kit/redoubt.sh).
- Source: https://github.com/stalwartlabs/mail-server
- Copyright: Stalwart Labs
- License: AGPL-3.0-only
- License text:
  https://github.com/stalwartlabs/mail-server/blob/main/LICENSES/AGPL-3.0-only.txt
- Conveyance: wired but not conveyed at this release (the tier is off).

## NetBird (mesh)

The NetBird repository licenses all parts under BSD-3-Clause except the
directories management/, signal/, relay/ and combined/, which are
AGPL-3.0. See the LICENSE files inside those directories.

- Client and agent binary: the kit downloads the NetBird client from the
  NetBird GitHub releases at install time. The version is the latest
  release at install time (resolved through the GitHub API); the kit
  verifies the vendor checksum file after download. License:
  BSD-3-Clause.
- Management server image: netbirdio/netbird-server, tagged with the
  resolved NetBird release version. It runs the management and signal
  parts, licensed AGPL-3.0.
- Management dashboard image: netbirdio/dashboard:latest, digest
  sha256:203b2dc90dc20d3fd45729caac7c922deb399586a68202e0a35be099720bac7d.
  Source: https://github.com/netbirdio/dashboard. License: AGPL-3.0.
- Source: https://github.com/netbirdio/netbird
- Copyright: Copyright (c) 2022-2026 NetBird GmbH & AUTHORS
- License texts:
  https://github.com/netbirdio/netbird/blob/main/LICENSE (BSD-3-Clause
  text and the AGPL-3.0 split),
  https://github.com/netbirdio/dashboard/blob/main/LICENSE
- Conveyance: all NetBird parts are downloaded at install time. The kit
  does not redistribute them.

## Apache Guacamole (remote desktop, optional profile)

- Images: guacamole/guacd:1.5.5, digest
  sha256:38232cae271361ef53db46faf5c49fe64049a1320a05b82c597425b69d6ce77e,
  and guacamole/guacamole:1.5.5, digest
  sha256:0f62f6d17ab379e46aa66874b2ff564dab856a6ef5e754a69cbb34c32d3e588a.
- Source: https://github.com/apache/guacamole-server and
  https://github.com/apache/guacamole-client
- Copyright: The Apache Software Foundation
- License: Apache-2.0
- License texts: https://github.com/apache/guacamole-server/blob/master/LICENSE
  and https://github.com/apache/guacamole-client/blob/master/LICENSE.
  The guacamole-client LICENSE also carries notices for bundled
  subcomponents: Carlito (SIL Open Font License), the DuoWeb Java SDK
  (BSD-3-Clause) and the TOTP reference implementation (BSD-3-Clause).
- Conveyance: downloaded at install time (optional profile).

## Encrypted vault binaries

### gocryptfs (fuse motor)

- Version: v2.6.1. The kit downloads the static amd64 release tarball
  from the gocryptfs GitHub releases and pins the archive sha256
  (VAULT_TGZ_SHA in kit/redoubt.sh).
- Source: https://github.com/rfjakob/gocryptfs
- Copyright: Copyright (c) 2015 Jakob Unterwurzacher
- License: MIT
- License text: https://github.com/rfjakob/gocryptfs/blob/master/LICENSE
- Conveyance: downloaded at install time.

### fscrypt (ext4/f2fs motor)

- Version: v0.3.7. The kit prefers the distribution package
  (fscrypt, libpam-fscrypt on Debian and Ubuntu). When that fails it
  downloads a build from the Redoubt release channel
  (https://install.tryredoubt.com/install/fscrypt-bin.tar.gz), built
  from google/fscrypt v0.3.7.
- Source: https://github.com/google/fscrypt
- Copyright: Copyright 2017 Google Inc.
- License: Apache-2.0
- License text: https://github.com/google/fscrypt/blob/master/LICENSE
  and https://www.apache.org/licenses/LICENSE-2.0
- Conveyance: the release-channel tarball is redistributed by the kit's
  release channel. The distribution package comes from the distro
  archive at install time.

## Icons

The icon files embedded in kit/redoubt.sh decode to the files in the
icons/ directory of this repository; those files are redistributed by
the kit. The larger sets ride release-channel tarballs fetched at
install time from install.tryredoubt.com and are served by the local
edge; those tarballs are redistributed by the kit's release channel.
See icons/ATTRIBUTION.md for the full file map.

### dashboard-icons (Homarr)

- Source: https://github.com/homarr-labs/dashboard-icons
- Copyright: Copyright (c) 2024 Bjorn Lammers, Meier Lukas, Thomas
  Camlong and Homarr Labs
- License: Apache-2.0
- License text: https://github.com/homarr-labs/dashboard-icons/blob/main/LICENSE
  and https://www.apache.org/licenses/LICENSE-2.0
- Conveyance: redistributed by the kit (embedded files plus the svg and
  png channel tarballs).

### selfhst/icons

- Source: https://github.com/selfhst/icons
- Copyright: the selfhst/icons contributors
- License: CC-BY-4.0
- Attribution: the icons are by the selfhst/icons contributors
  (https://github.com/selfhst/icons). The kit conveys the files
  unmodified; no changes were made.
- License text: https://github.com/selfhst/icons/blob/main/LICENSE and
  https://creativecommons.org/licenses/by/4.0/
- Conveyance: redistributed by the kit (embedded files).

### simple-icons

- Source: https://github.com/simple-icons/simple-icons
- License: CC0-1.0
- License text: https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md
  and https://creativecommons.org/publicdomain/zero/1.0/
- The edge serves the marks under /cdn/simpleicons/ per
  icons/ATTRIBUTION.md. The marks themselves may be trademarks of their
  owners; CC0 does not waive trademark rights.

### Papirus

- Source: https://github.com/PapirusDevelopmentTeam/papirus_icons (the
  path the kit mirrors); the Papirus Linux theme repository
  (papirus-icon-theme) is licensed GPL-3.0.
- Copyright: the Papirus Development Team
- License: GPL-3.0
- License text: the channel tarball (icons-papirus.tar.gz) bundles the
  GPL-3.0 text as src/LICENSE;
  https://www.gnu.org/licenses/gpl-3.0.html
- Conveyance: redistributed by the kit's release channel (channel
  tarball).

### App marks (icons/apps/)

- The immich, nextcloud, searxng and pihole marks label each project's
  tile. Each mark is a trademark of its project and is not covered by
  the kit's license.

## License texts

- AGPL-3.0: https://www.gnu.org/licenses/agpl-3.0.html
- GPL-3.0: https://www.gnu.org/licenses/gpl-3.0.html
- LGPL-3.0: https://www.gnu.org/licenses/lgpl-3.0.html
- Apache-2.0: https://www.apache.org/licenses/LICENSE-2.0
- MIT: https://opensource.org/license/mit
- BSD-3-Clause: https://opensource.org/license/bsd-3-clause
- PostgreSQL License: https://www.postgresql.org/about/licence/
- CC-BY-4.0: https://creativecommons.org/licenses/by/4.0/
- CC0-1.0: https://creativecommons.org/publicdomain/zero/1.0/

## Trademarks

Glances, Bulwark, llama.cpp, Homarr, Home Assistant, Immich, Stalwart,
NetBird, Apache Guacamole, PostgreSQL and other product names are
trademarks of their respective owners. Naming them here does not imply
endorsement by, or affiliation with, those projects.
