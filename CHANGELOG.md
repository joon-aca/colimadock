# Changelog

## 0.5.0

- Start, stop, or restart a saved remote Colima profile from the menu bar. Stop and Restart ask for confirmation and show the target Mac and profile.
- Start and Restart wait for Docker to respond before marking the profile online. Starting a profile preserves its saved Colima settings.
- A confirmed stop closes the profile’s local port forwards. Extra forwards can still reach the remote Mac over SSH when Docker is unavailable.

## 0.4.1

- **About ColimaDock** in the menu bar shows the installed version and build, copyright, and quick-start tips for managing local containers, connecting to remote Colima hosts, and routing Docker commands. It also links to the full user guide.

## 0.4.0

Remote hosts as easy to manage as this Mac.

- **Remote connections get their own section**, like **This Mac**: containers sit at the top level of the menu instead of one submenu deeper, with the status line (and any **⚠︎** problem) right under the connection's name. Status details, **Edit Connection…** and **Forget Connection** move to **Connection Controls**.
- **Opening the menu catches remotes up**: a remote not checked in the last 10 seconds is re-checked right away, failure backoff or not, and its running containers' CPU and memory are sampled in the same pass. **Refresh** (⌘R) does the same for all of them. This replaces **Check Now** and **Sample CPU & Memory**, which closed the menu with no visible result. The menu can't change while it's open, so new results show on the next open. Remote stats are labelled **Stats from 14:52:07** so an old sample can't pass as live.
- Fixed: SSH tunnels outlived ColimaDock when it was killed (`pkill`, `make run`) or crashed, and kept holding their ports here, so the next launch marked them **⚠︎ in use on this Mac**. ColimaDock now quits normally on SIGTERM, SIGINT and SIGHUP, and at launch it stops tunnels an earlier instance left behind and removes their folders in `/tmp`.
- Fixed: an empty **ColimaDock Settings** window opened at every launch.

## 0.3.0

Remote containers' ports on this Mac, like a local VM.

- **Published ports are forwarded automatically.** A port a remote container publishes appears on the same port on this Mac's `localhost` and goes away when the container stops, the way a local Colima VM forwards ports. One SSH connection per remote carries them all.
- A port already in use on this Mac is left alone and marked **⚠︎ in use on this Mac** in the menu; it's retried on every check.
- Container and connection submenus list what's forwarded: `localhost:5432 → postgres`.
- **Localhost forwards** are now **Extra forwards**, for remapped ports and non-Docker services. They take priority over a published port on the same local number.
- Remote connections show the same status dots as containers: **●** online, **○** stopped, **⚠︎** SSH, Colima or Docker not answering.
- The **Sparky** preset now fills in `default`: Sparky runs a single VM.

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
