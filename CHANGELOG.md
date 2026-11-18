# Changelog

## 0.2.1

- Fixed: the 0.2.0 download contained the 0.1.0 app, so it had no remote hosts. Swift 6.4 moved where universal builds are written, and the build script copied a stale binary from the old location. It now asks SwiftPM for the path and refuses a binary missing either architecture.

## 0.2.0

Remote hosts: watch Colima on another Mac over SSH.

- **Remote Hosts**: add a Colima profile on another Mac (**Add Remote Colima…**) and see its VM and containers in their own menu; start and stop containers there and sample their stats on request. Connections are saved across launches.
- Connect as another account with `user@host`, such as `worker@sparky-local`. The **Sparky** preset fills in Sparky's `worker` account and its everyday `offload` VM.
- Remote checks run about every 20 seconds and back off after connection failures. SSH runs non-interactively, requires a known host key, and never forwards your agent.
- Optional **Localhost forwards** (`29120:19120`) stay connected while ColimaDock runs and retry after a disconnect.
- Local Docker profiles beyond `default` are discovered and grouped under **This Mac**.
- **Docker Commands**: `ColimaDock docker -- …` runs a Docker command on a preferred remote host and falls back to the same profile on this Mac.
- Fixed: saving a remote connection did nothing in release builds. A control-character check rejected every name, so the dialog never accepted a host. `make app` now runs the tests in release as well as debug.

## 0.1.0

First release.

- Lists the Docker containers in Colima's `default` VM from the menu bar, with start/stop and snapshot stats
- Starts and stops the Colima VM
- Detects stale Lima disk locks left by a killed VM (the "in use by instance" start failure); **Clear Lock & Start Colima** fixes it in one click
- Finds leftover Colima/Lima background processes that nothing tracks anymore and stops them
- Universal build (Apple Silicon + Intel), signed with Developer ID and notarized
