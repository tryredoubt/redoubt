# Security

## Reporting a vulnerability

Send reports privately to hello@tryredoubt.com. Do not open a public
issue or mention the details in public channels before a fix ships.

A useful report states:

- the affected component (the kit script, the installer wrapper, one of
  the wired services, the update flow);
- the version, or the kit release line and sha256 of the script;
- steps to reproduce, with the smallest possible case;
- the impact you expect (what an attacker gains, on which system);
- whether you plan to publish the report and when;
- a contact for follow-up.

Do not send secrets. No private keys, passwords, mail credentials,
database dumps, or personal data. Describe the issue; the reporter and
the maintainer will exchange anything else as needed.

## Supported versions

The current release line only. Older release lines are not patched. If
your issue is in an old line, test it against the current one first.

## Disclosure process

The maintainer acknowledges the report, works on a fix, and coordinates
the release with the reporter. There are no fixed response-time
promises. Security work is best effort, and the kit's license
(AGPL-3.0, see LICENSE) states the warranty and liability terms that
apply to it.

## Security and crypto limitations

### The local CA

The kit runs its own certificate authority (Caddy's internal CA) under
/var/lib/redoubt/caddy-local/caddy/pki/authorities/local/. The edge
serves HTTPS over this CA.

- What trusting it means: importing the CA root (root.crt) into a
  device tells that device to trust any certificate this CA signs, now
  and until the root is revoked or replaced. Import the root only on
  devices the owner controls, and check the CA fingerprint on a trusted
  local console before importing.
- Protect the private key: the CA key files (including
  intermediate.key) live on the host in the path above. Anyone with
  those files can mint certificates the owner's devices will trust.
  Restrict access to the machine and that directory, back the keys up
  carefully, and never publish them.
- Rotate and revoke: if the key is exposed, replace the CA, reissue the
  edge certificates, and reimport the new root on every device that
  trusted the old one. A CA trust relationship is only as strong as
  the key's secrecy.

### The release-signing key

The kit verifies its release (sha256 plus an ed25519 signature) before
install and update. The release-signing key is distinct from the local
CA: it signs Redoubt releases; the CA signs TLS certificates. A valid
signature proves a file came from the release key. It does not prove
the file has no vulnerabilities.

### The firewall

Which ports are reachable depends on several things, and on later
changes to any of them:

- the selected mode and the doors the kit opens for it;
- the effective host firewall and the Docker forwarding rules (the
  iptables DOCKER-USER chain and the nft table inet redoubt-dns);
- the router: port forwarding, UPnP, and the ISP's own settings;
- the IPv4 and IPv6 configuration;
- any change made after install, by the owner or by software.

To verify: from a second network, test the ports that should be open
and the ones that should be closed against the machine's real address;
on the host, check the published ports (docker ps) and the firewall
rule set. Repeat the check after every kit update, mode switch, or
router change.

### What this document does not promise

No software can promise complete security. The kit is provided under
AGPL-3.0 without warranty, and the authors' liability is limited as
stated in sections 15 and 16 of LICENSE.
