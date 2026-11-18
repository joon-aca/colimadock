# Sparky: office Docker host

The MacBook keeps the editor, Docker CLI, and ColimaDock. Sparky keeps the
Docker daemon, build caches, volumes, and checkouts used as bind mounts.

| Need | From the MacBook | Destination |
|---|---|---|
| Run Docker commands | `docker --context sparky-komodo …` | The exact Docker Unix socket on Sparky |
| Use a container service | Localhost port forward maintained by ColimaDock | A service port on Sparky's loopback |
| Monitor containers | ColimaDock → Sparky | SSH, Colima status, and the same Unix socket |

Use the existing `sparky-local` alias (`joon-m1.local`) in the office. Prefer
Ethernet; if `.local` doesn't resolve from office Wi-Fi, reserve Sparky's DHCP
address and use a private DNS name for the alias. Keep Docker on its Unix
socket and bind application ports to loopback. The existing Cloudflare `sparky`
alias is a manual Terminal route; verify its login and forwarding before relying
on it. For unattended access offsite, use a separate SSH alias for a private VPN
address. ColimaDock probes over direct SSH and won't initiate Cloudflare Access.

## 1. Provision the first profile

Sparky has 16 GB RAM, eight cores, and about 112 GiB free. Its Docker Desktop
engine was inactive, and Colima was absent. Install current tools with the
existing Apple Silicon Homebrew. Sparky's old Docker CLI was in `/usr/local/bin`:

```sh
ssh sparky-local
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
brew install colima docker docker-compose docker-buildx
colima version
docker --version
```

Follow `brew info docker-compose docker-buildx` for plugin discovery and verify
`docker compose version` and `docker buildx version`. Put Homebrew first in
Sparky's noninteractive SSH PATH as well. Docker contexts invoke `docker` by
name on the remote, so check `ssh sparky-local 'command -v docker; docker --version'`
from the MacBook without the interactive `export` above.

Clone `komodo-tools` and the Komodo fork (`~/dev/github/komodo`, or set
`KOMODO_REPO`) on Sparky. Check out the commits you want to test and keep
secrets out of Git. Run `make dev` from `komodo-tools`. It provisions
`komodo-dev` with six vCPUs, 10 GiB RAM, a 40 GiB Docker disk, and just the
project's designated host directory mounted. Its build script can add 8 GiB
of guest swap for Rust. Build once and check memory pressure, host disk space,
and `df -h /var/lib/docker` inside the VM.

Komodo Periphery can control its entire Docker engine. Keep that engine for
Komodo tests. If you later move MongoDB or Redis, provision a separate
`office-dev` profile at roughly two vCPUs and 2–3 GiB RAM to start, and recheck
host pressure with both VMs running. Move MongoDB and any durable Redis data
via backups and restores. Named volumes live on their original daemon. Keep the
original copies until the restored services pass application checks.

## 2. Connect the MacBook

On Sparky, `colima status --profile komodo-dev --json` reports `docker_socket`.
Use its absolute path in a named context on the MacBook. The standard path is
shown below. This works while the laptop's daemon is running too:

```sh
docker context create sparky-komodo --docker 'host=ssh://sparky-local/Users/joon/.colima/komodo-dev/docker.sock'
docker --context sparky-komodo version
docker --context sparky-komodo ps -a
```

Use explicit `--context` in scripts and for commands that change state. Image
builds can transfer their build context to Sparky. Compose files that mount
`.:/app` or another host path at runtime need that checkout or file on Sparky;
use an editor remote session or SSH to run those stacks there. Changing
contexts won't move existing volumes or publish ports to the MacBook.

In ColimaDock, choose **Add Remote Colima…** and enter `Sparky`, `sparky-local`,
and `komodo-dev`. Set **Localhost forwards** to `29120:19120` and open
`http://127.0.0.1:29120`. This lets both Komodo instances run during the pilot.
After the MacBook's copy stops, use `19120:19120` to get the old URL back.
ColimaDock restores saved forwards when it opens and retries if SSH drops.
Add it to macOS Login Items to start at sign-in. **Online** means the app
reached Docker. The forwarding status separately tells you whether SSH is
listening on the MacBook. Check the service with:

```sh
curl --fail --max-time 3 http://127.0.0.1:29120/version
```

Keep Komodo bound to Sparky loopback. Add multiple forwards with commas. If
moving MongoDB or Redis, use `27017:27017` or `6379:6379` after stopping the
local listener and choosing the authoritative copy of the data. Clear the
forward in the connection settings or quit ColimaDock to free the local port.
For a one-off tunnel when ColimaDock is closed, use
`ssh -NT -o ExitOnForwardFailure=yes -L 127.0.0.1:29120:127.0.0.1:19120 sparky-local`.
Supervise the VM itself with `launchctl` on Sparky.

## 3. Keep it running

Use AC and prevent idle system sleep while plugged in. Leave the signed-in
session locked. Check how this Mac recovers from a power failure. Sparky has
FileVault enabled: plan for an authorized unlock after a cold restart and a
user login for the LaunchAgent. Apple silicon running macOS 26 or later can
unlock FileVault over SSH with Remote Login and network access; test that
separately and have an on-site recovery path. Keep FileVault enabled. If the
host must come back from a power outage without intervention, use a dedicated
Linux host with that boot requirement instead of a macOS user session.

After the pilot build, install the example
[LaunchAgent](examples/dev.joon.sparky.komodo-dev.plist), which supervises a
foreground Colima process. Confirm the home, executable, and profile paths.
Run the following on Sparky as its signed-in user:

```sh
label=dev.joon.sparky.komodo-dev
agent="$HOME/Library/LaunchAgents/$label.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 600 /path/to/dev.joon.sparky.komodo-dev.plist "$agent"
plutil -lint "$agent"
# Stop the pilot VM before handing it to launchd.
colima stop --profile komodo-dev
launchctl bootstrap "gui/$(id -u)" "$agent"
launchctl print "gui/$(id -u)/$label"
```

Add `restart: unless-stopped` in Compose for the long-lived services you want
back automatically. The current Komodo dev Compose file has no restart policy.
For a pilot, `docker update --restart unless-stopped` can set this for existing
containers when invoked with the explicit remote context. Put it in Compose
before calling the setup permanent, since recreating a container discards
runtime-only changes. Keep one-shot migrations and test fixtures on demand.
Test workload readiness after every planned VM restart.

For maintenance, use `launchctl bootout "gui/$(id -u)/$label"` before stopping
the profile. Check `colima status --profile komodo-dev`, and stop the profile
normally if it is still running. Use `bootstrap` again to restart supervision.
Logs are in `~/Library/Logs/sparky-komodo-dev.log`. Check log sizes and free
disk; keep Compose definitions in Git and back up durable data separately.

## Cutover and rollback

1. From normal office Wi-Fi, verify SSH, the explicit Docker context, a full
   build, one test container start/stop from ColimaDock, and the forwarded URL.
2. Disconnect the MacBook and confirm Sparky keeps running. Test a VM restart
   and then a planned Sparky restart through unlock/login. Confirm the
   context, forward, and app work again after reconnecting.
3. Once ready, stop only the MacBook's `komodo-dev` profile with
   `colima stop --profile komodo-dev` on the MacBook. Keep `default` for Sammy
   MongoDB and MWB Redis. Compare Activity Monitor and swap after a work session.
4. To fall back, close the SSH forwards, start `komodo-dev` on the MacBook,
   and use `docker --context colima-komodo-dev …`. Its prior state is separate.

References: [Colima foreground startup](https://colima.run/docs/faq/#does-colima-support-autostart),
[Docker SSH socket paths](https://docs.docker.com/reference/cli/docker/#using-ssh-sockets),
[bind mounts](https://docs.docker.com/engine/storage/bind-mounts/#considerations-and-constraints),
[Docker restart policies](https://docs.docker.com/engine/containers/start-containers-automatically/),
[Apple FileVault over SSH](https://support.apple.com/guide/security-pdf/managing-filevault-sec8447f5049/web).
