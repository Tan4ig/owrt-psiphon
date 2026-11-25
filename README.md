# OWRTPsiphon

[English](README.md) | [Русский](README_RU.md)

**OWRTPsiphon** is a lightweight OpenWrt LuCI web controller that manages a Psiphon tunnel powered by `bepass-org/warp-plus` (`--cfon`) and exposes a persistent local SOCKS5 proxy.

## Features

* **Standalone SOCKS5 Proxy:** Fully independent service. Use `socks5://192.168.1.1:8086` in any LAN application (Telegram, browsers, torrent clients).
* **Perfect for Steer:** Exposes a persistent endpoint `socks5://192.168.1.1:8086#OWRTPsiphon` that remains static across country switches.
* **Non-Intrusive:** Does not modify Steer, Zapret, firewall/nftables, PPPoE, Wi-Fi, or routing tables.
* **Compact LuCI Dashboard:** Live status, exit IP, latency-sorted country list, auto-selection, and one-click updates.
* **Automation & Failover:** Boot autostart and scheduled health checks (1/6/12/24h) with automatic failover to the lowest-latency working country.

## Installation

Run one of the following commands via SSH on your OpenWrt router:

Using `curl`:
curl -fsSL "https://raw.githubusercontent.com/Tan4ig/owrt-psiphon/main/install.sh" -o /tmp/owrt-install.sh && sh /tmp/owrt-install.sh

Using `wget` (if `curl` is not installed):
wget -O /tmp/owrt-install.sh "https://raw.githubusercontent.com/Tan4ig/owrt-psiphon/main/install.sh" && sh /tmp/owrt-install.sh

After installation, open **Services → OWRTPsiphon** in LuCI. 
To use with **Steer**, paste `socks5://192.168.1.1:8086#OWRTPsiphon` into **Steer → VPN → Subscription → Custom Servers**.

---
*Disclaimer: This is an independent educational project. Not affiliated with Psiphon Inc., Cloudflare, or the `bepass-org` team. The `warp-plus` binary is downloaded directly from its official MIT-licensed repository.*
