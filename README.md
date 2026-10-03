<p align="center">
  <img src=".github/icon.png?v=3" width="128" alt="SheepDrop app icon">
</p>

# 🐑 SheepDrop

**A native macOS file-transfer app built for network engineers — SFTP, SCP, FTP, and TFTP, as both a client and a built-in server.**

SheepDrop is written in SwiftUI + AppKit (Swift 6) and designed around the daily workflow of
moving configs and firmware to and from switches, routers, firewalls, and access points:
browse a device over SFTP/SCP like a dual-pane file manager, or flip on a built-in server so
the device can pull (or push) files from your Mac with its own `copy scp:` / `copy tftp:`
command — no separate TFTP daemon to configure.

## ⬇️ Download

[![Download SheepDrop for macOS](https://img.shields.io/badge/Download-SheepDrop_1.3_for_macOS-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/bestonehxh/SheepDrop/releases/latest)

**[Get the latest release →](https://github.com/bestonehxh/SheepDrop/releases/latest)** — download the `.zip`, unzip, and drag **SheepDrop.app** into `Applications`.

> The build is not notarized, so macOS will warn on first launch —
> right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/SheepDrop.app`
>
> Requires macOS 26 (Tahoe) or later, Apple Silicon.

## The Sheep family 🐑

SheepDrop is one of a few small native macOS apps for network engineers:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTerm/main/.github/icon.png?v=3" width="48" height="48" alt="SheepTerm"> | **[SheepTerm](https://github.com/bestonehxh/SheepTerm)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepTerm/releases/latest) | SSH / Serial / local-shell terminal for network engineers |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepText/main/.github/icon.png?v=3" width="48" height="48" alt="SheepText"> | **[SheepText](https://github.com/bestonehxh/SheepText)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepText/releases/latest) | Fast text editor with tree-sitter highlighting and a JavaScript plugin system |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepDrop/main/.github/icon.png?v=3" width="48" height="48" alt="SheepDrop"> | **[SheepDrop](https://github.com/bestonehxh/SheepDrop)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepDrop/releases/latest) | SFTP / SCP / FTP / TFTP file transfer — client and built-in server |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTap/main/.github/icon.png?v=3" width="48" height="48" alt="SheepTap"> | **[SheepTap](https://github.com/bestonehxh/SheepTap)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepTap/releases/latest) | Menu-bar viewer for your Mac's network interfaces with click-to-copy |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepPing/main/.github/icon.png?v=3" width="48" height="48" alt="SheepPing"> | **[SheepPing](https://github.com/bestonehxh/SheepPing)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepPing/releases/latest) | Continuous multi-host ping monitor with per-host logs and CSV export |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepLog/main/.github/icon.png?v=2" width="48" height="48" alt="UncleSpy"> | **[UncleSpy](https://github.com/bestonehxh/SheepLog)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepLog/releases/latest) | Syslog viewer, SNMP tester and packet capture with TCP and 802.1X ladder diagrams — and a Troubleshoot page that reads all three |
| <img src="https://raw.githubusercontent.com/bestonehxh/LabDC/main/.github/icon.png" width="48" height="48" alt="LabDC"> | **[LabDC](https://github.com/bestonehxh/LabDC)**<br>[⬇️ Download](https://github.com/bestonehxh/LabDC/releases/latest) | Active Directory–compatible domain controller with RADIUS for 802.1X and a lab CA |

## Features

### Connect to a device (client)
- **SFTP** and **SCP** on SheepDrop's own SSH implementation — no OpenSSL or libssh, only
  Apple's crypto frameworks underneath. Browse the device in a **dual-pane** view
  (This Mac ⇄ device) with a `cd`-style address bar on each side
- **Fast transfers** — SFTP keeps many requests in flight (like OpenSSH), so large firmware
  images move at full link speed; a running transfer can be **cancelled** at any time, and an
  interrupted download never leaves a half-written file behind
- **SCP browses like WinSCP** — when a device serves the SFTP subsystem, an SCP session
  becomes fully browsable instead of blind put/get
- **FTP** and **TFTP** for older gear
- **Legacy SSH that just works on old switches** — modern algorithms first, with the legacy
  KEX, ciphers, MACs, and `ssh-rsa` host keys that old Cisco IOS / Aruba / HPE gear is limited
  to, so a modern device is never downgraded but an old one still connects
- **Host-key pinning** in `~/.ssh/known_hosts` — a changed key is refused, never silently accepted
- **Add Device** (⌘T) — type `admin@10.0.0.1`, pick the protocol, and go
- Sidebar with **host groups** (drag to reorder) and recent connections; each host shows
  whether its session is connected

### Let a device reach your Mac (built-in server)
- One-switch **TFTP**, **SFTP / SCP**, and **FTP** servers so a device can run
  `copy scp://user@mac/file …`, `copy tftp://mac/file …`, etc. and pull from (or back up to)
  a served folder on your Mac
- **SCP / SFTP share one SSH server on port 22** (falls back to 2222 if macOS Remote Login
  owns 22) — `copy scp:` on switches always uses port 22, and SheepDrop binds it
- **Live request log** and a **transfer bar** showing upload/download progress, kept as
  history when a transfer finishes
- **Allow-writes** toggle for device backups, applied live without a restart; uploads land
  atomically, so an interrupted push never replaces a good file

### Security
- The SSH and FTP servers authenticate against an app-defined **virtual username + password** —
  never your macOS account — and nothing is served before login succeeds
- Every server is **confined to the served folder**, symlinks included
- **Brute-force and flood limits** — failed logins drop the connection, and connections per
  device are capped; TFTP replies from a fresh port per transfer (RFC 1350)
- Server host keys are private to your user account; passwords are stored **only in the
  macOS Keychain** — never in config files or exports

### Design
- A calm, readable monochrome interface with large type, light and dark appearance, and one
  place for every action (plus the menu bar)

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- To build: Xcode 26+ (no Homebrew dependencies)

## Building

```bash
xcodebuild -project SheepDrop.xcodeproj -scheme SheepDrop -configuration Release build
```

The app is built at
`~/Library/Developer/Xcode/DerivedData/SheepDrop-*/Build/Products/Release/SheepDrop.app`.

## Acknowledgements

- SSH is implemented in Swift on top of Apple CryptoKit and Security.framework (shared with
  [SheepTerm](https://github.com/bestonehxh/SheepTerm)).

## License

[MIT](LICENSE) © 2026 bestonehxh
