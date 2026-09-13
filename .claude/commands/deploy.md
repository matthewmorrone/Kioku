---
description: Build Kioku and install/launch on the connected iPhone (Camelopardalis)
---

Build Kioku for an iPhone and install/launch it on the device, like Xcode's Run button.

Device: Camelopardalis (iPhone 17 Pro), id `00008150-00140DC10123C01C`. (Monoceros, iPhone 15 Pro,
id `FEB1FCF4-369B-5AE3-B521-24AA1FEA25D9`, was the previous connected device and may be
`unavailable` now — if this device id stops working, run `xcrun devicectl list devices` to find
the current `available (paired)` iPhone and update this file.)
Bundle ID: `matthewmorrone.Kioku`.
Built `.app` ends up at `/tmp/kioku-build/Build/Products/Debug-iphoneos/Kioku Reader.app`.

`devicectl` talks to a device-communication daemon over IPC; under a sandboxed shell this hangs
or times out with "Timed out waiting for CoreDeviceService to fully initialize" instead of failing
fast. Run every `xcodebuild`/`devicectl` command below with the sandbox disabled.

Steps to perform — run them in order, stopping if any fails. If `$ARGUMENTS` contains `--release`, swap `Debug` for `Release` in both the configuration flag and the `Debug-iphoneos` path.

1. **Build for the device.** Run in the background and wait for completion. Treat `BUILD FAILED` or any `error:` line as fatal.
   ```bash
   xcodebuild -scheme Kioku -configuration Debug -destination 'platform=iOS,id=00008150-00140DC10123C01C' -derivedDataPath /tmp/kioku-build build
   ```

2. **Install the app on the device.** This replaces any prior install of the same bundle ID.
   ```bash
   xcrun devicectl device install app --device 00008150-00140DC10123C01C "/tmp/kioku-build/Build/Products/Debug-iphoneos/Kioku Reader.app"
   ```

3. **Terminate any running Kioku process.** Install replaces the bundle on disk but doesn't kill the running app, so the next launch would just foreground the old process and reuse stale in-memory state (e.g. the dictionary trie built once at startup). Safe no-op when Kioku isn't running.
   ```bash
   PID=$(xcrun devicectl device info processes --device 00008150-00140DC10123C01C 2>&1 | grep -i "Kioku" | head -1 | awk '{print $1}')
   if [ -n "$PID" ]; then
     xcrun devicectl device process terminate --device 00008150-00140DC10123C01C --pid "$PID"
     sleep 1
   fi
   ```

4. **Launch the app.** Skip this step if `$ARGUMENTS` contains `--no-launch`.
   ```bash
   xcrun devicectl device process launch --device 00008150-00140DC10123C01C matthewmorrone.Kioku
   ```

Report success in one line: "Built, installed, and launched Kioku on Camelopardalis." If launch was skipped, say "Built and installed Kioku on Camelopardalis." If the device is not connected (`devicectl` errors with `No such device`), say so and stop — do not retry.
