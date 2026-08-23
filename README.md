# TV Tweak

[![ci](https://github.com/26zl/tv-tweak/actions/workflows/ci.yml/badge.svg)](https://github.com/26zl/tv-tweak/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Debloat and tune Android TV devices over ADB. No root, fully reversible, keeps DRM playback
working. One generic POSIX `sh` script; everything that depends on the device lives in a profile
directory under `devices/`.

| Profile | Device | Verified on |
| --- | --- | --- |
| [`firetv-stick-hd`](devices/firetv-stick-hd/README.md) | Amazon Fire TV Stick 4K Max (`karat` / `AFTKRT`) | Fire OS 8.1.8.0 |
| [`sharp-4k-googletv`](devices/sharp-4k-googletv/README.md) | Sharp 4K UHDTV (MediaTek MT9676 / `maniatika`) | Google TV, Android 14 |

Every package list was taken from `pm list packages` on the device it names. Generic Android TV
lists are how Widevine gets broken: `com.amazon.firebat` looks like a service worth killing and is
the Prime Video app; `com.mediatek.tv.oneworld.tvcenter` looks like bloat and is the HDMI input
switcher. The logic is `pm disable-user` in a loop — the value is the curated list.

## Setup

Needs `adb` and `curl` on the host, and ADB debugging on the device — each profile's README has
the steps. Android Studio installs `platform-tools` without putting it on `PATH`, so the standard
SDK locations are checked as a fallback; set `ADB=/path/to/adb` if yours lives somewhere else.

macOS and Linux both work, and CI runs the checks on both. The device is reached over TCP, so
Linux needs no udev rules.

The profile is picked by matching `ro.product.model` against `devices/*/device.conf`; pass
`--device <profile>` to choose explicitly. With exactly one device attached, or exactly one
advertising Android's wireless debugging over mDNS, it is detected automatically:

```sh
export DEVICE=192.168.1.50:5555        # only if several devices are attached
```

## Usage

```text
./tweak.sh [--device <profile>] <command>

  info                 device summary
  backup               snapshot which packages are already disabled; pins the device serial
  debloat [tiers...]   disable packages (default tiers come from the profile)
  restore              undo everything: packages and settings
  tune                 apply the profile's settings.conf, trim caches
  apps                 sideload the profile's apps.conf (checksum-pinned)
  verify [--deep]      DRM props, protected packages, drift, launcher; --deep launches media apps
  status               list currently disabled packages
  launch <package>     start an app with no home-screen icon
  home [package]       show or set the launcher
  dns [host|off|show]  system-wide DNS-over-TLS
  sleep <min|never>    display-off and device-sleep timers
```

First run — `verify` first, so you can tell a regression from a pre-existing fault:

```sh
./tweak.sh verify && ./tweak.sh backup && ./tweak.sh debloat && ./tweak.sh tune
./tweak.sh verify
```

`debloat` appends everything it disables to `backups/<profile>/applied.txt` and every setting
written goes to `backups/<profile>/settings.txt` with its original value. `restore` reverses
exactly those, so it stays correct after you edit `packages.conf` and never touches what you had
already disabled yourself.

`backup` also records `ro.serialno`; every later run refuses to touch a device with a different
serial, which guards against DHCP handing the IP to something else. `EXPECT_SERIAL=` overrides it.

Run `verify` after reboots and after installing anything: some firmware re-enables packages on
its own, and `verify` reports exactly which ones drifted.

## Profiles

```text
devices/<profile>/
  README.md        what was verified, the tiers, and the device's quirks
  device.conf      model, device codename, default tiers, accepted launchers, props to verify
  packages.conf    tiered package list with rationale
  keep.conf        packages that are never disabled, whatever packages.conf says
  apps.conf        sideload targets as <package>|<url>|<sha256>; `play` as url opens the store
  settings.conf    <namespace> <key> <value> lines applied by `tune`
```

Adding a device is adding a directory. Start from `pm list packages` on the device, put the
launcher, input stack, DRM services and every streaming app in `keep.conf`, and grow
`packages.conf` from what `dumpsys meminfo` and `dumpsys package` tell you. `test.sh` checks that
every profile parses, names a launcher, has all of its default tiers, and never lists a kept
package.

## Safety

`keep.conf` is enforced independently of `packages.conf`, so editing the package list cannot
break playback. `verify` checks the DRM props named in `device.conf`, that nothing kept is
disabled, that disabled packages stayed disabled, that settings held, that sideloads are present,
and that the home screen resolves to an accepted launcher. `--deep` also launches each installed
streaming app; it takes over the TV.

`verify` shows the DRM flags are advertised, not that a licence was fetched. Playback was confirmed
by hand on each verified device after the full debloat and `tune`.

`apps` downloads over HTTPS and aborts on a checksum mismatch; the pins are recorded in each
`apps.conf` together with the date. Both verified devices are 32-bit (`armeabi-v7a`) and reject
`arm64-v8a`-only builds.

## Layout

```text
tweak.sh         the tool
test.sh          self-test for the parsing logic and every profile; no device required
devices/         one directory per device, see Profiles
backups/<profile>/
  state-*.txt    what was already disabled before the tool ran
  applied.txt    what the tool disabled; the exact input to `restore`
  settings.txt   every setting written, as `<namespace> <key> <applied> <original>`
  serial.txt     the device this profile was first used on
```

## License

MIT — see [LICENSE](LICENSE).
