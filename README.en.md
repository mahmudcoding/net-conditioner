# Net Conditioner

**[Русская версия → README.md](README.md)**

A macOS menu-bar app that limits internet speed, adds latency, and drops
packets — so you can see how any app or site behaves on a bad connection.
One click turns an "EDGE" profile on, one click turns it off.

Unlike browser DevTools throttling, the shaping works at the system level:
it affects **all** programs and **all** protocols, including UDP — video
calls, VoIP, and games, not just page loads.

## Install

1. Download `Net-Conditioner-x.y.z-macOS-arm64.zip` from
   [Releases](https://github.com/mahmudcoding/net-conditioner/releases).
2. Unzip and drag `Net Conditioner.app` into Applications.
3. On first launch: right-click → Open (the app is ad-hoc signed, so macOS
   asks once).
4. A speedometer appears in the menu bar.

Requirements: macOS 13+, Apple Silicon. The app updates itself (Sparkle):
"Check for Updates…" in the menu, plus an automatic daily check.

## Use

Click the speedometer → pick a profile → enter the administrator password
(the standard macOS dialog asks for it; the app never sees the password).
While shaping is active the icon turns into a tortoise. "Turn Off" restores
normal networking. "Custom…" takes exact numbers, and "Check Connection…"
measures the actual speed, latency, and loss.

| Profile | Down | Up | RTT | Loss |
|---|---|---|---|---|
| EDGE | 240 kbit | 200 kbit | 400 ms | — |
| 3G | 780 kbit | 330 kbit | 100 ms | — |
| LTE | 50 Mbit | 10 Mbit | 50 ms | — |
| DSL | 2 Mbit | 256 kbit | 5 ms | — |
| Very Bad | 1 Mbit | 1 Mbit | 500 ms | 10% both ways |
| Packet Loss 8% | — | — | — | 8% upload |
| Packet Loss 15% | — | — | — | 15% upload |
| Blackout | — | — | — | 100% both ways |

## From the terminal

The `netcond` script in this repository does everything the app does:

```bash
./netcond preset 3g
./netcond set --down 1mbit --up 256kbit --rtt 300 --loss 5
./netcond set --loss-up 8 --host example.com
./netcond status
./netcond verify
./netcond off
```

`--host` limits shaping to traffic to/from specific hosts (default: the
whole machine). `--dry-run` prints the commands without changing anything.
Re-applying replaces the active profile; nothing stacks.

## How it works

Shaping uses the stock macOS machinery: dummynet pipes (`dnctl`) plus the
pf anchor `netcond` (`pfctl`). Everything lives only in kernel memory:

- `/etc/pf.conf` on disk is never modified;
- turning off removes only its own pipes (9101/9102), its own anchor, and
  its own pf reference — other rules are left alone;
- rebooting the Mac is guaranteed to restore everything.

## Good to know

- Without `--host` the **whole machine** slows down — your browser,
  messengers, and background sync included. Remember "Turn Off".
- Don't run Apple's Network Link Conditioner at the same time — two shapers
  interfere with each other (`netcond status` warns about foreign pipes).
- Local traffic (localhost) is never shaped.

## Uninstall

"Turn Off", then delete the app from Applications and `rm -rf ~/.netcond`.

## Build from source

```bash
npm run test:engine
npm run build:app
```

Releasing (maintainer): `npm run release:mac -- 0.1.0` — builds, signs the
Sparkle feed with the Keychain key, tags, and publishes the GitHub release.
