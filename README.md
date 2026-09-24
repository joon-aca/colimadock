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

## Build

```bash
swift build -c release
./build-app.sh
open ColimaDock.app
```

The app is a plain SwiftPM/AppKit menu bar app. No Electron, no background service, no special permissions dance.
