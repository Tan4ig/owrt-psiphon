# OWRTPsiphon

Experimental LuCI controller for `bepass-org/warp-plus` in Psiphon mode on OpenWrt 25.x (aarch64).

> Alpha software. Tested against one AX3000T/OpenWrt environment only. It is not a universal OpenWrt package.

## Features in this first alpha

- Native LuCI page under **Services → OWRTPsiphon**.
- procd service wrapper for `warp-plus --cfon`.
- Country selector: NL, DE, BE, FR, GB, PL, CZ, AT, CH, US.
- Stable local SOCKS URL: `socks5://192.168.1.1:8086#OWRTPsiphon`.
- Explicit adoption of an already-running manual Psiphon process.
- SOCKS probe and sequential country scan (one temporary tunnel at a time).
- Does not rewrite Steer configuration or firewall rules.

## Install

After publishing this repository, run on the router (replace `OWNER/REPOSITORY` with the GitHub path):

```sh
curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/install.sh | sh -s -- OWNER/REPOSITORY
```

The installer downloads the repository archive, checks the ARM64 binary SHA256, and installs the LuCI page. Review the script before running it.

For a local checkout/archive, run from its root:

```sh
sh install.sh
```

The installer does not start or enable the service automatically because port 8086 may already be used by a manually started Psiphon tunnel feeding Steer.

## Steer

Use this SOCKS5 node in Steer:

```text
socks5://192.168.1.1:8086#OWRTPsiphon
```

The address stays the same when the selected Psiphon country changes. The page only displays/copies the link; it does not overwrite `/etc/steer/spec.json` or the existing Steer subscription.

## Important limitations

- `--country` chooses a country for Psiphon's internal selection; it does not pin a permanent physical server IP.
- Country scan is sequential and can take several minutes. It measures a real HTTPS request through SOCKS, not ICMP ping. It probes on a separate localhost port, leaving the active tunnel up during the scan; if a different country wins, the managed tunnel reconnects once at the end.
- Scan currently accepts a result only when the geolocated exit country matches the requested country.
- Auto-selection is a manual scan action in this alpha; periodic autonomous failover is not implemented yet.
- Firewall hardening for port 8086 is intentionally not installed until LAN-client blocking is verified without disrupting the local Steer connection.
- `on_fail` in Steer is not changed.

## Uninstall

Keep binary/config/cache:

```sh
sh uninstall.sh
```

Remove data too:

```sh
PURGE=1 sh uninstall.sh
```

## Upstream binary

`warp-plus` is downloaded from the upstream `bepass-org/warp-plus` v1.2.6 ARM64 release and the archive SHA256 is verified. The upstream project is MIT licensed. The OWRTPsiphon scripts are experimental and provided as-is.
