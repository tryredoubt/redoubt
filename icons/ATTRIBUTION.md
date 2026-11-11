# Icons

The icons in this folder are the exact files the installer embeds and
decodes to disk at install time. They are published here, byte for byte,
so anyone can verify them against their sources without running the kit.

## Sources and licenses

- gh/homarr-labs/dashboard-icons/: from https://github.com/homarr-labs/dashboard-icons (Apache-2.0). The paths mirror the upstream repo, so each file can be diffed directly against its source.
- gh/selfhst/icons/: from https://github.com/selfhst/icons (CC-BY-4.0). The paths mirror the upstream repo.
- gh/PapirusDevelopmentTeam/papirus_icons/: from
  https://github.com/PapirusDevelopmentTeam/papirus_icons (GPL-3.0). The kit
  fetches this set as a release-channel tarball (icons-papirus.tar.gz) and the
  local edge serves it to the panel tiles under the same upstream path.
- apps/: small service marks the dashboard shows (immich, nextcloud, searxng, pihole). Each mark belongs to its respective project.
- logo.png and favicon.ico: Redoubt brand assets.

The base64 blobs inside kit/redoubt.sh decode to these same bytes. To
verify: decode any blob from the script and diff it against the matching
file here, or against the upstream repository at the mirrored path.
