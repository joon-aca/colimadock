# ColimaDock

A tiny macOS menu bar app for the thing you probably actually care about in Colima: the Docker containers.

ColimaDock groups local containers by profile under **This Mac** and gives each remote connection its own section, named after it, laid out the same way. Open any container in the menu to start or stop it.

## Why another Colima menu bar app?

Colima is great. Menu bar apps are great. But the existing lightweight options tend to answer one question:

> Is the Colima VM running?

That is useful, but it is not the whole story. Most of the time the question is:

> Is my Redis/Postgres/API container actually running?

ColimaDock is built around that second question. The VM is treated as the runtime, not the main character. If the default Colima VM is stopped, ColimaDock lets you start it. Once it is running, the menu becomes a container list.

## What it does

- Shows Docker containers from the default Colima VM and discovers other local Docker profiles, such as `komodo-dev`
- Starts and stops individual containers
- Shows snapshot container stats for running containers in the default local profile, and for remote profiles each time you open the menu
- Starts and stops the default Colima VM from a secondary menu
- Detects stale Lima disk locks left by a killed VM (the "in use by instance" start failure) and clears them, on its own or as part of starting
- Spots leftover Colima/Lima background processes that nothing tracks anymore (their pid file is gone) and stops them
- Refreshes the local profile every 5 seconds
- Lists each remote connection's containers at the top level, like a local profile, with its details and actions under **Connection Controls**
- Checks remote inventories about every 20 seconds and backs off after connection failures. Opening the menu re-checks any remote not checked in the last 10 seconds and samples its containers' CPU and memory; the menu can't change while it's open, so the result shows the next time you open it
- Forwards the ports remote containers publish to the same port on this Mac's `localhost`, like a local Colima VM, while ColimaDock is running
- Can route Terminal Docker commands to a preferred remote and fall back to this Mac

## What it does not do

- Start or stop non-default VMs
- Replace Docker Desktop
- Delete containers, images, or volumes
- Open logs or shells

At least for now, it is intentionally just a small status-and-start/stop tool.

## Remote Colima

Choose **Add Remote Colima…** and select **Sparky** to fill in `worker@sparky-local` and `default`, Sparky's one VM. For another machine, enter a name, an SSH alias or hostname such as `office-mac.local` (as `user@host` to log in as another account), and the remote Colima profile. Add one connection per profile you want to watch. A profile that isn't running shows as **Stopped**. **Save** adds a section for the connection and keeps it across launches. The alias or hostname must already work over the LAN or private network with `BatchMode=yes`. Verify and trust a new host's SSH key once in Terminal.

### Ports

A port a remote container publishes shows up on the same port on this Mac's `localhost`, the way a local Colima VM does it: `docker --context sparky run -p 5432:5432 postgres` gives you `localhost:5432` here. Forwards follow the containers, appearing within about 20 seconds of a start and closing after a stop, over one SSH connection per remote. Each container's submenu and **Connection Controls** list them. A port something on this Mac already uses is left alone and marked **⚠︎ … in use on this Mac**; it's retried on every check, so it takes over once the port is free.

For anything else, such as a remote port under a different local number or a service outside Docker, enter pairs in **Extra forwards**: `29120:19120` maps this Mac's port 29120 to the remote host's port 19120. These win over a published port with the same local number.

Forwards run while ColimaDock does. Add it to macOS Login Items if you want them up when you sign in.

### Sparky

Sparky's one VM belongs to its `worker` account and runs while `worker` is logged in on its screen. `make sparky` in the `sparky-vm` tool sets it up and points the `sparky` Docker context at it.

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

Runs the tests in debug and release, builds `ColimaDock.app` for this Mac, and launches it. The tests run in release too because the shipped app is a release build, and a release-only miscompile once rejected every remote host while the debug tests passed. The app is a plain SwiftPM/AppKit menu bar app. No Electron, no background service, no special permissions dance.

## Release

```bash
make release VERSION=0.2.1
```

Builds a universal binary, signs it with your Developer ID (hardened runtime), notarizes and staples it, zips it, tags `v0.2.1`, pushes, and publishes the GitHub release with a SHA-256. It refuses to run off a dirty or stale `master`, or without a `## 0.2.1` section in `CHANGELOG.md` (that section becomes the release notes). If publishing fails after tagging, re-running resumes.

One-time setup: notarization credentials live in your keychain, never in the repo. `make release` prints the exact `xcrun notarytool store-credentials` command if they are missing.
