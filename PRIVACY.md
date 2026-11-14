# Privacy

This statement covers the Redoubt kit: kit/redoubt.sh, the installer
wrapper, and the files the kit places on the machine, as written at
this release. It does not cover the tryredoubt.com website, the desktop
or phone apps, or the Windows installer. Questions about this statement:
hello@tryredoubt.com.

## Where data lives

The kit deploys self-hosted services on the owner's machine. Those
services store their configured data (photos, files, mail, search
indexes, dashboards, home automation state) on that machine, under the
service volumes in /var/lib/redoubt. Redoubt does not operate these
services and does not receive their data. The kit keeps no copy of it.

## Network requests the kit makes

At install and update time the kit contacts:

- the GitHub API (api.github.com) for the latest NetBird release, the
  release lookup used to resolve the version the kit downloads;
- the Redoubt release channel (install.tryredoubt.com) for the signed
  update payload and the icon and fscrypt tarballs;
- the container registries (docker.io and ghcr.io) for the pinned
  container images;
- the distribution package archives for packages the kit installs from
  the distro repositories.

When the mesh is used, the kit and the NetBird agent contact the NetBird
API (api.netbird.io and app.netbird.io) for the setup key and the mesh
account flows.

Optional services make their own requests once enabled: the ad shield
refreshes its blocklists from the list publishers, and each service may
contact its own provider for updates, integrations, or the features the
owner enables in it. Those flows belong to the services, not to the
kit.

## Telemetry

The kit sends no telemetry to Redoubt. It contains no analytics, no
usage reporting, and no phone-home beyond the requests listed above.

This claim covers the kit flows only and was written against the
current code. It does not cover what the optional services do.

## The optional services and their providers

Enabling or using a service can send data to that service's provider.
Read the provider's own policy before enabling it:

- NetBird (mesh): https://netbird.io/privacy
- Immich: https://immich.app/privacy
- Home Assistant: https://www.home-assistant.io/privacy/
- Homarr: https://homarr.dev/
- Stalwart Mail: https://stalw.art/
- Bulwark: see the project's own site and registry page
- Apache Guacamole: https://privacy.apache.org/
- Docker Hub (image pulls): https://www.docker.com/legal/
- GitHub and GitHub Container Registry (release lookups, release
  downloads and ghcr.io pulls):
  https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement
- jsDelivr (the icon CDN paths the local edge mirrors):
  https://www.jsdelivr.com/terms/privacy-policy

## What this statement does not promise

Nothing in this statement promises that data can never leave the home
network. The services the owner enables, their providers, and the
owner's own configuration determine where data goes. The kit does not
guarantee a fully offline machine. See SECURITY.md for the limits of
the local security model.
