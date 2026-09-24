# ColimaDock

A tiny macOS menu bar app for the thing you probably actually care about in Colima: the Docker containers.

ColimaDock watches Colima's `default` VM, then lists the Docker containers inside it directly from the menu bar. Start them, stop them, glance at their stats, and get back to whatever you were building.

## Why another Colima menu bar app?

Colima is great. Menu bar apps are great. But the existing lightweight options tend to answer one question:

> Is the Colima VM running?

That is useful, but it is not the whole story. Most of the time the question is:

> Is my Redis/Postgres/API container actually running?

ColimaDock is built around that second question. The VM is treated as the runtime, not the main character. If the default Colima VM is stopped, ColimaDock lets you start it. Once it is running, the menu becomes a container list.

## What it does

- Shows all Docker containers from the default Colima VM
- Starts and stops individual containers
- Shows snapshot container stats for running containers
- Starts and stops the default Colima VM from a secondary menu
- Detects stale Lima disk locks left by a killed VM (the "in use by instance" start failure) and clears them, on its own or as part of starting
- Spots leftover Colima/Lima background processes that nothing tracks anymore (their pid file is gone) and stops them
- Refreshes every 5 seconds

## What it does not do

- Manage multiple Colima profiles
- Replace Docker Desktop
- Delete containers, images, or volumes
- Open logs or shells

At least for now, it is intentionally just a small status-and-start/stop tool.

## Requirements

- macOS 13.0+
- [Colima](https://github.com/abiosoft/colima)
- Docker CLI configured for Colima

## Install

Download the latest `ColimaDock-x.y.z.zip` from [Releases](https://github.com/joon-aca/colimadock/releases), unzip it, and drag `ColimaDock.app` to `/Applications`. Releases are universal (Apple Silicon + Intel), signed with Developer ID, and notarized, so it opens without Gatekeeper complaints.

## Build

```bash
make run
```

Builds `ColimaDock.app` for this Mac and launches it. The app is a plain SwiftPM/AppKit menu bar app. No Electron, no background service, no special permissions dance.

## Release

```bash
make release VERSION=0.1.0
```

Builds a universal binary, signs it with your Developer ID (hardened runtime), notarizes and staples it, zips it, tags `v0.1.0`, pushes, and publishes the GitHub release with a SHA-256. It refuses to run off a dirty or stale `master`, or without a `## 0.1.0` section in `CHANGELOG.md` (that section becomes the release notes). If publishing fails after tagging, re-running resumes.

One-time setup: notarization credentials live in your keychain, never in the repo. `make release` prints the exact `xcrun notarytool store-credentials` command if they are missing.
