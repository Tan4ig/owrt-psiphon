# OWRTPsiphon

[English](README.md) | [Русский](README_RU.md)

**OWRTPsiphon** is a lightweight OpenWrt LuCI web controller that manages a Psiphon tunnel powered by `bepass-org/warp-plus` (`--cfon`) and exposes a persistent local SOCKS5 proxy for **Steer** or other applications.

## What is Psiphon?

Psiphon is a **censorship circumvention tool**, not a traditional VPN. It uses a combination of secure communication and obfuscation technologies to help users access blocked content. Key differences from a VPN:
- **Purpose:** Designed to bypass internet censorship, not to provide guaranteed anonymity.
- **Architecture:** Uses a network of proxy servers with various protocols (SSH, VPN, HTTP proxy) that can automatically switch to evade blocking.
- **Limitations:** Free Psiphon servers may be slower and are not intended for privacy-critical tasks. They do not guarantee anonymity.

**OWRTPsiphon** is simply a controller that manages the `warp-plus` engine on OpenWrt. It is **not** a VPN service, and the author of this project is **not** the creator of Psiphon, Cloudflare, or `warp-plus`.

## Features

* **Standalone SOCKS5 Proxy:** Fully independent service. Use `socks5://192.168.1.1:8086` in any LAN application.
* **Perfect for Steer & Zapret-Manager:** Exposes a persistent endpoint `socks5://192.168.1.1:8086#OWRTPsiphon` that remains static across country switches.
* **Zapret-Manager Integration:** Supports `--no-luci` installation. The backend can be controlled via `ubus call owrt-psiphon ...` allowing ZM to build its own UI.
* **Non-Intrusive:** Does not modify existing firewall/nftables, PPPoE, or routing tables.
* **Automation & Failover:** Boot autostart and scheduled health checks (1/6/12/24h) with automatic failover to the lowest-latency working country.

## Installation

Run one of the following commands via SSH on your OpenWrt router:

Using `curl`:

    curl -fsSL "https://raw.githubusercontent.com/Tan4ig/owrt-psiphon/main/install.sh" -o /tmp/owrt-install.sh && sh /tmp/owrt-install.sh

For integration without the LuCI interface (e.g., for Zapret-Manager):

    curl -fsSL "https://raw.githubusercontent.com/Tan4ig/owrt-psiphon/main/install.sh" -o /tmp/owrt-install.sh && sh /tmp/owrt-install.sh --no-luci

After installation, open **Services → OWRTPsiphon** in LuCI. Paste `socks5://192.168.1.1:8086#OWRTPsiphon` into **Steer → VPN → Custom Servers**.

---
*Disclaimer: This is an independent educational project. Not affiliated with Psiphon Inc., Cloudflare, or the `bepass-org` team. The `warp-plus` binary is downloaded directly from its official MIT-licensed repository.*