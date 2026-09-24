# Changelog

## 0.1.0

First release.

- Lists the Docker containers in Colima's `default` VM from the menu bar, with start/stop and snapshot stats
- Starts and stops the Colima VM
- Detects stale Lima disk locks left by a killed VM (the "in use by instance" start failure); **Clear Lock & Start Colima** fixes it in one click
- Finds leftover Colima/Lima background processes that nothing tracks anymore and stops them
- Universal build (Apple Silicon + Intel), signed with Developer ID and notarized
