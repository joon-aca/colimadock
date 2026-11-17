# ColimaDock

A tiny macOS menu bar app for the thing you probably actually care about in Colima: the Docker containers.

ColimaDock groups local containers by profile under **This Mac** and shows configured remote connections under **Remote Hosts**. Open any container in the menu to start or stop it.

## Why another Colima menu bar app?

Colima is great. Menu bar apps are great. But the existing lightweight options tend to answer one question:

> Is the Colima VM running?

That is useful, but it is not the whole story. Most of the time the question is:

> Is my Redis/Postgres/API container actually running?

ColimaDock is built around that second question. The VM is treated as the runtime, not the main character. If the default Colima VM is stopped, ColimaDock lets you start it. Once it is running, the menu becomes a container list.

## What it does

- Shows Docker containers from the default Colima VM and discovers other local Docker profiles, such as `komodo-dev`
- Starts and stops individual containers
- Shows snapshot container stats for running containers in the default local profile and on demand for remote profiles
- Starts and stops the default Colima VM from a secondary menu
- Detects stale Lima disk locks left by a killed VM (the "in use by instance" start failure) and clears them, on its own or as part of starting
- Spots leftover Colima/Lima background processes that nothing tracks anymore (their pid file is gone) and stops them
- Refreshes the local profile every 5 seconds
- Shows remote Colima profiles and their containers in a separate menu for each connection
- Checks remote inventories about every 20 seconds, backs off after connection failures, and samples remote container stats on request
- Keeps optional localhost port forwards connected while ColimaDock is running
- Can route Terminal Docker commands to a preferred remote and fall back to this Mac

## What it does not do

- Start or stop non-default VMs
- Replace Docker Desktop
- Delete containers, images, or volumes
- Open logs or shells

At least for now, it is intentionally just a small status-and-start/stop tool.

## Remote Colima

Choose **Add Remote Colima…** and enter a name, SSH alias, and remote profile. Use an SSH alias that already works over the LAN or a private network with `BatchMode=yes`. For a new host, verify and trust its SSH host key once. ColimaDock uses your existing SSH keys and polls independently of the active Docker context.

Enter `29120:19120` in **Localhost forwards** to map this Mac's port 29120 to
the remote Mac's port 19120. Add more pairs separated by commas. ColimaDock
starts the tunnel when it opens, retries after a disconnect, and releases the
ports when it quits or you clear the field. Add ColimaDock to macOS Login Items
if you want your forwards to come up when you sign in.

The [Sparky runbook](docs/sparky.md) covers setup, Docker contexts, localhost forwards, restart behavior, and cutover.

### Prefer a remote Docker host

Under **Docker Commands**, pick a saved remote and choose **Copy Docker Command Prefix**. In Terminal, paste the prefix and add a command such as `ps` or `compose up -d`. For an app in `/Applications`, the full command looks like this:

```bash
/Applications/ColimaDock.app/Contents/MacOS/ColimaDock docker -- ps
```

The launcher checks Docker on the preferred host first, then checks the Colima profile with the **same name** on this Mac. It prints its choice to stderr and runs the command once on that engine. Use `docker --target` to check which host the launcher would pick, or `docker --remote -- …` and `docker --local -- …` to require one host. These options follow the `ColimaDock` executable path.

The launcher doesn't change Docker's current context or start either VM. Start the local profile yourself if you need it while the remote is away. To leave the MacBook's resources free in the office, keep the local copy of that workload stopped. Containers, named volumes, and published ports stay with their own engines; remote bind mounts use paths on the remote host. Use `--remote` or `--local` for a series of commands that must all use the same data. Separate builders selected explicitly with Buildx have their own targets.

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
