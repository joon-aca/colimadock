# ColimaDock

ColimaDock is a macOS menu bar app for Docker containers running in Colima. See which containers are running, start and stop them, and check resource usage on this Mac or another Mac over SSH. ColimaDock can also make remote container services available on your own `localhost`.

## Install

1. On macOS 13 or later, download the latest `ColimaDock-x.y.z.zip` from [GitHub Releases](https://github.com/joon-aca/colimadock/releases).
2. Unzip the download, move **ColimaDock.app** to **Applications**, and open it.
3. Click the shipping box icon in the menu bar. In version 0.4.1 or later, choose **About ColimaDock** for the installed version and quick-start help.

GitHub release builds are signed, notarized, and work on Apple Silicon and Intel Macs.

## Manage containers on this Mac

Install [Colima](https://github.com/abiosoft/colima) and the Docker CLI on this Mac. Under **This Mac**, ColimaDock groups containers by their Colima Docker profile. Open a container’s submenu to see its status and published ports or to start or stop it. Running containers in the default profile also show CPU and memory snapshots.

Use **VM Controls (default)** to start or stop the default Colima VM. If a stale Lima disk lock blocks startup, this menu offers to clear the lock. Use the Colima CLI to start or stop other VMs, and the Docker CLI to create containers, view logs, or open a shell.

## Connect to another Mac

The remote Mac needs SSH access, Colima, and the Docker CLI. Start and Restart require a Colima version that supports the `--activate` and `--save-config` flags on `colima start`. Connect as the account that owns the Colima profile, and start that profile with the Docker runtime. ColimaDock uses direct SSH over a reachable network, such as a LAN or private VPN, with a trusted host key and authentication that works without an interactive prompt.

1. On this Mac, save the remote host and account under one name by adding an entry to `~/.ssh/config`. Replace the values below with your own.

   ```sshconfig
   Host build-mac
       HostName build-mac.local
       User dev
   ```

2. Run `ssh build-mac` in Terminal once. Verify the host’s fingerprint before trusting it, and set up key-based authentication if needed. Confirm that the login works without prompting.

   ```sh
   ssh -o BatchMode=yes -o StrictHostKeyChecking=yes build-mac true
   ```

3. In ColimaDock, choose **Add Remote Colima…**. If there’s a **Server** picker, select **Custom server**. Enter a display **Name**, the **SSH host**, and the **Colima profile**. For example, use `Build Mac`, `build-mac`, and `default`. The menu also accepts a hostname or `user@host`.
4. Choose **Save**. The connection gets its own menu section and is restored when you reopen ColimaDock. You can add one connection per host and profile combination.

Open a container in the remote section to start or stop it on that host. When a saved profile is stopped, choose **Start `<profile>` VM** in the section or under **Connection Controls** to start it and wait for Docker to respond. For a running profile—including when Docker stops answering—use **Restart `<profile>` VM…** or **Stop `<profile>` VM…** under **Connection Controls** (or **Restart `<profile>` VM…** directly in the section when Docker is unavailable). Stopping a profile closes its active port forwards on this Mac and leaves it stopped until you start it again. **Connection Controls** also shows SSH, VM, and forwarding details and lets you edit or forget the connection.

ColimaDock checks healthy connections about every 20 seconds. Opening the menu requests a fresh check and CPU and memory snapshots if the previous check was at least 10 seconds ago. Choose **Refresh** (⌘R) to request a check and stats for every remote. Reopen the menu to see the results. The **Stats from** timestamp shows when the sample was taken.

### Remote Mac setup and recovery limits

- **Reboot and login.** A per-user `LaunchAgent` in `~/Library/LaunchAgents` starts Colima only after that macOS account signs in, not while the Mac sits at the pre-login window. Use `RunAtLoad` without `KeepAlive` if you want a profile stopped from ColimaDock to stay stopped; a `KeepAlive` agent restarts a stopped foreground VM until unloaded with `launchctl bootout`. See Apple's [launchd guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html).
- **Power and sleep.** The remote Mac must be awake and reachable over SSH. Keep it on power and prevent automatic sleeping when the display is off in [Mac sleep settings](https://support.apple.com/guide/mac-help/mchle41a6ccd/mac). Closing a Mac laptop's lid puts it to sleep unless it meets Apple's [closed-display requirements](https://support.apple.com/en-us/102501).
- **FileVault.** After a restart on a FileVault-enabled Mac, unlock the disk and sign in as the Colima user before normal SSH and Colima operations resume. Apple silicon Macs with macOS 26 or later support remote FileVault unlock over SSH when Remote Login is enabled and a network connection is available; treat unlock as a separate operator step before ColimaDock reconnects. See [Apple Platform Security](https://support.apple.com/en-mide/guide/security-pdf/sec8447f5049/1/web/1).

## Access remote services on localhost

While ColimaDock is running and the remote profile is online, it forwards TCP ports published by running remote containers to the same ports on this Mac. For example, if a web app publishes port `8080` on the remote Mac, open `http://localhost:8080` on this Mac. The forward follows the container and profile as they start and stop.

Use **Connection Controls → Edit Connection… → Extra forwards** to use a different local port or reach a service on the remote host’s loopback address. For example, `18080:8080` maps local port `18080` to remote port `8080`. Separate multiple mappings with commas. Local ports in this field must be between 1024 and 65535. An extra forward takes precedence over automatic forwarding on the same local port. Extra forwards can keep serving traffic over SSH while Docker is unavailable. ColimaDock closes them when it confirms that the profile is stopped and restores them when it sees the profile running again.

If a local port is already taken, **Connection Controls** shows it as **in use on this Mac**. ColimaDock retries on subsequent checks. Forwards are bound to this Mac’s loopback interface and close when you quit ColimaDock.

## Run Docker commands in Terminal

With Docker CLI installed on this Mac, open **Docker Commands** in ColimaDock, choose a saved remote, and select **Copy Docker Command Prefix**. Paste the prefix into Terminal and append a command such as `ps`. For an app in **Applications**, the result looks like this:

```sh
/Applications/ColimaDock.app/Contents/MacOS/ColimaDock docker -- ps
```

The launcher checks Docker on the preferred remote first. If that engine is unavailable, it tries a running Colima profile with the same name on this Mac. It prints the chosen target and runs the command once.

In ColimaDock 0.4.1, use an SSH alias with a `User` entry in `~/.ssh/config` to route Docker commands through a specific SSH account.

Pass these options after `docker` in the ColimaDock command:

| Arguments | What they do |
| --- | --- |
| `--target` | Print the target ColimaDock would choose. |
| `--remote -- ps` | Run `ps` on the preferred remote only. |
| `--local -- ps` | Run `ps` on the matching local profile only. |

Use a single target for a series of commands that need the same containers or volumes. Containers and volumes stay on the engine where you create them, and remote bind mounts refer to paths on the remote host.

## Build from source

On a Mac with the Swift toolchain and Xcode command-line tools, run `make app` to test and build `ColimaDock.app` for this Mac. Run `make test` to run just the debug and release tests. Use `make run` to build and launch the app, replacing any running ColimaDock instance.

For maintainers, `make release VERSION=x.y.z` builds a universal app, signs it with Developer ID, notarizes it, and publishes a tagged GitHub release. The script requires a clean, up-to-date `master`, a matching [changelog](CHANGELOG.md) entry, a Developer ID signing identity, a configured `notarytool` keychain profile, and an authenticated GitHub CLI.
