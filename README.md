# Proxmox Manager for iOS

A native SwiftUI application for managing Proxmox Virtual Environment (PVE) servers from iPhone and iPad.

## Features
- 🖥️ Manage multiple Proxmox servers (credentials stored in the iOS Keychain)
- 🚀 Start, stop, shutdown, and reboot VMs and LXC containers
- 📊 Real-time node and guest resource monitoring (CPU / memory / disk / uptime)
- 🔐 Self-signed certificate support with first-use SHA-256 fingerprint pinning
- 📱 Native iOS design for iPhone and iPad
- 🧪 Unit tests for model decoding and request encoding
- 📋 Global task center for tracking long-running Proxmox operations
- 🔄 Foreground auto-refresh with last-updated timestamps

## Requirements
- iOS 16.0+
- Xcode 26.0+ (required for current App Store submissions)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the Xcode project is generated from `project.yml`)
- Proxmox VE 6.0+

## Building

This repository does not commit a `.xcodeproj`. It is generated from `project.yml`
with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open ProxmoxManager.xcodeproj
```

Then configure your development team in Xcode and build to a device or simulator.

## Unsigned IPA (CI)

The GitHub Actions workflow `.github/workflows/build-unsigned-ipa.yml` builds an
**unsigned** IPA on every push to `main`/`master`, on pull requests, and on
manual `workflow_dispatch`. It:

1. Generates the Xcode project with XcodeGen.
2. Archives with code signing disabled (`CODE_SIGNING_ALLOWED=NO`).
3. Packages the resulting `.app` into `Payload/…` and zips it to
   `ProxmoxManager-unsigned.ipa`.
4. Uploads the IPA as a build artifact.

The unsigned IPA is suitable for sideloading tools that re-sign the app
(AltStore, Sideloadly, TrollStore, etc.). It is **not** installable directly on
a stock device without signing.

## Security
- Passwords and pinned certificate fingerprints are stored in the iOS Keychain.
- Self-signed certificates require explicit first-use SHA-256 fingerprint confirmation and are scoped to the configured host.
- Certificate changes are rejected after a fingerprint has been pinned.
- App Transport Security remains enabled by default; use a CA-signed certificate for production deployments.
- For production use, configure a proper CA-signed certificate on your Proxmox server and leave "Allow self-signed certificate" turned off.

## License
MIT License - see LICENSE file for details.
