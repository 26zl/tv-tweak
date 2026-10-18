# TV Tweak

[![ci](https://github.com/26zl/tv-tweak/actions/workflows/ci.yml/badge.svg)](https://github.com/26zl/tv-tweak/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Debloat and tune Android TV devices over ADB. No root, fully reversible, keeps DRM playback
working. One generic POSIX `sh` script; everything that depends on the device lives in a profile
directory under `devices/`.

| Profile | Device | Verified on |
| --- | --- | --- |
| [`firetv-stick-4k-max-2023`](devices/firetv-stick-4k-max-2023/README.md) | Amazon Fire TV Stick 4K Max (`karat` / `AFTKRT`) | Fire OS 8.1.8.0 |
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
`--device <profile>` to choose explicitly. Commands that change the TV refuse one whose
`ro.product.device` is not the profile's — another device's package list is how playback breaks —
unless `--force` says you compared the two with `verify` first. A different Android release, or a
firmware update since the TV's first backup, is reported as a warning. (`firetv-stick-hd` was the
first name of the Fire TV profile; it still works and points at `firetv-stick-4k-max-2023`.) With exactly one device attached, or exactly one
advertising Android's wireless debugging over mDNS, it is detected automatically:

```sh
export DEVICE=192.168.1.50:5555        # only if several devices are attached
```

## Usage

```text
./tweak.sh [options] <command> [arguments]

  info                  device summary
  backup                snapshot which packages are already disabled (the first one is kept as the baseline)
  debloat [tiers...]    disable packages (default tiers come from the profile)
  restore               re-enable the packages this tool disabled and roll its settings back
  tune                  apply the profile's settings.conf, trim caches
  apps                  sideload the profile's apps.conf (checksum-pinned)
  verify                DRM props, protected packages, drift, launcher
  status                list currently disabled packages
  launch <package>      start an app with no home-screen icon
  home [package|show]   show or set the launcher
  dns [host|off|auto|show]    Private DNS: a DNS-over-TLS hostname, off, or Android's default
  sleep [minutes|never|show]  display-off and device-sleep timers

options, anywhere on the line:
  --device <profile>    use devices/<profile> instead of matching the TV's model
  --deep                verify: also launch each installed media app (takes over the TV)
  --new-device          start a separate record for a second TV of the same model
  --force               change a TV that is not the device its profile was built for
  --dry-run             show what a command would change; nothing on the TV or in its state changes
  -h, --help            usage; never touches the TV
  --version             print the version
```

Arguments are checked before anything connects: an unknown tier, a hostname that Private DNS
cannot use (an IP address, a name without a dot), or anything with shell syntax in it is refused
with exit code 2.

First run — `verify` first, so you can tell a regression from a pre-existing fault, and a dry run
to see exactly what will change:

```sh
./tweak.sh verify
./tweak.sh debloat --dry-run && ./tweak.sh tune --dry-run
./tweak.sh backup && ./tweak.sh debloat && ./tweak.sh tune
./tweak.sh verify
```

`debloat` appends everything it disables to `applied.txt` in the TV's state directory (see
[Layout](#layout)), and every setting written goes to `settings.txt` with its original value,
recorded before the write. `restore` reverses exactly those, so it stays correct after you edit `packages.conf` and
never touches what you had already disabled yourself. Packages and settings are restored
independently; whatever fails stays recorded and `restore` exits 1, so running it again finishes
the job. A TV that stops answering ends the run instead of turning every remaining step into a
failure, and each adb call gives up after `TWEAK_TIMEOUT` seconds (60 by default). A read that
fails is an error, never an empty answer.

State is kept per TV, keyed by its serial number (`ro.serialno`). A TV the profile has not been
used on before is refused, which guards against DHCP handing the IP to another TV; for a second TV
of the same model, add `--new-device` once and it gets its own record.

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
break playback. The streaming apps named in `media_apps` are protected the same way. It fails
closed: without a `keep.conf` that lists packages, or with a profile line it cannot read safely (a
package name with shell syntax in it, a plain-http download, a missing checksum), nothing runs.
Every profile file is read the same way, so CRLF endings, stray spaces and `# comments` after an
entry are harmless; `device.conf` is read as data and never executed. `verify` checks the DRM props named in `device.conf`, that nothing kept is
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
test-flows.sh    every command end to end against a simulated TV; no device required
devices/         one directory per device, see Profiles
```

The undo record lives outside the clone, one directory per TV, so a re-clone or `git clean -fdx`
cannot take it away: `~/.local/state/tv-tweak/<profile>/<serial>/` (or under `$XDG_STATE_HOME`),
`~/Library/Application Support/tv-tweak/<profile>/<serial>/` on macOS, or `$TWEAK_STATE` if set.
Every command that changes something prints the path.

```text
<profile>/<serial>/
  baseline.txt     what was already disabled before the tool first ran; never rewritten
  snapshot-*.txt   every later `backup`
  applied.txt      what the tool disabled; the exact input to `restore`
  settings.txt     every setting written, as `<namespace> <key> <applied> <original>`
  build.txt        the firmware build the TV had at the first backup
  log.txt          one line per run that changed something, in UTC
```

Keep it until you have run `restore`: it is the only record of what to undo. State from earlier
versions, in `backups/<profile>/` inside the clone, moves there the first time its TV is connected.

## License

MIT — see [LICENSE](LICENSE).
