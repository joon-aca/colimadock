# ColimaDock

A native macOS menu bar app for managing Docker containers running in Colima's default VM.

ColimaDock is intentionally small: it checks the `default` Colima profile, lists Docker containers when that VM is running, and exposes start/stop controls from the menu bar.

## Features

- Shows all Docker containers from the default Colima VM
- Starts and stops individual containers
- Shows snapshot container stats for running containers
- Starts and stops the default Colima VM from a secondary menu
- Refreshes every 5 seconds

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
