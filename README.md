# Amazon Fire TV Stick Tweak

[![ci](https://github.com/26zl/firestick-tweak/actions/workflows/ci.yml/badge.svg)](https://github.com/26zl/firestick-tweak/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Debloat and tune an Amazon Fire TV Stick over ADB. No root, fully reversible, keeps DRM playback
working.

Verified on **Fire TV Stick 4K Max (`karat` / `AFTKRT`), Fire OS 8.1.8.0, armeabi-v7a**. The
package list comes from `pm list packages` on that device, annotated with measured
`dumpsys meminfo` figures.

## Setup

Needs `adb` and `curl` on the host, and ADB debugging on the stick
(Settings → My Fire TV → Developer Options). With exactly one device attached it is detected
automatically.

Android Studio installs `platform-tools` without putting it on `PATH`, so the standard SDK
locations are checked as a fallback. Set `ADB=/path/to/adb` if yours lives somewhere else.

POSIX `sh`, no bashisms — macOS and Linux both work, and CI runs the checks on both. The device is
reached over TCP, so Linux needs no udev rules.

```sh
export DEVICE=192.168.1.50:5555        # only if several devices are attached
export EXPECT_SERIAL=XXXXXXXXXXXXXXXX  # refuse to run if DHCP moved that IP; see `info`
```

## Usage

```text
./firetweak.sh info                  device summary
./firetweak.sh backup                snapshot which packages are already disabled
./firetweak.sh debloat [tiers...]    disable packages (default: ads promo ota cruft)
./firetweak.sh restore               undo everything: packages and settings
./firetweak.sh perf                  animations off, auto-update off, location off, trim caches
./firetweak.sh apps                  sideload TV Bro, Obtainium, F-Droid
./firetweak.sh verify [--deep]       DRM and playback smoke test
./firetweak.sh status                list currently disabled packages
./firetweak.sh launch <package>      start an app with no home-screen icon
./firetweak.sh dns [host|off|show]   system-wide DNS-over-TLS
./firetweak.sh sleep <min|never>     display-off and device-sleep timers
```

First run — `verify` first, so you can tell a regression from a pre-existing fault:

```sh
./firetweak.sh verify && ./firetweak.sh backup && ./firetweak.sh debloat && ./firetweak.sh perf
./firetweak.sh verify
```

## Tiers

| Tier | Default | Effect |
| --- | --- | --- |
| `ads` | yes | Content recognition, advertising ID, telemetry emitters |
| `promo` | yes | Ambient screensaver, autoplaying trailers, store surfaces, Photos/Music |
| `ota` | yes | Forced-update components that *can* be disabled |
| `cruft` | yes | Tutorials, notices, stub apps, kids mode |
| `alexa` | no | Voice remote stops working |
| `smarthome` | no | Matter, Frustration Free Setup, Whisper\* discovery |
| `aggressive` | no | Silk, Appstore, ADM push, casting — read `packages.conf` first |
| `blocked` | never | Documentation only; Fire OS refuses these |

`debloat` appends everything it disables to `backups/applied.txt` and every setting it writes to
`backups/settings.txt` with the original value. `restore` reverses exactly those, so it stays
correct after you edit `packages.conf` and never touches what you had already disabled yourself.

## Limits without root

Twelve packages refuse to be disabled — `pm disable-user` raises
`SecurityException: Cannot disable a protected package` and `pm uninstall` returns
`DELETE_FAILED_INTERNAL_ERROR`. Amazon keeps a protected list inside `PackageManagerService`. It
includes the OTA updater and several metrics packages; they sit in the `blocked` tier for
reference.

**So the OTA client keeps running.** DNS is the only remaining enforcement point, and it works on
the device: Fire OS hides the Private DNS menu, but the Android 11 resolver still honours the
setting.

```sh
./firetweak.sh dns your-profile.dns.nextdns.io
```

You need a resolver with a **custom denylist** — general ad blockers do not cover Amazon's update
CDN. Note this bypasses a local Pi-hole; filter at the router instead if you prefer. Domains to
deny:

```text
amzdigitaldownloads.edgesuite.net
softwareupdates.amazon.com
device-metrics-us.amazon.com
device-metrics-us-2.amazon.com
*.amazon-adsystem.com
```

`com.amazon.vizzini` re-enables itself repeatedly, not once per boot — observed at 40 s, 275 s and
700 s of uptime within a single session, the last one right after an app was installed. `logcat`
shows `DeviceCapabilityServer` rebuilding the Alexa capability registry with `com.amazon.vizzini`
among its `owningPackages` each time, so package events look like a trigger; that is a hypothesis
from two coincidences, not a proven cause. Run `verify` after reboots *and* after installing
anything, and re-run `debloat alexa` when it reports drift. The other 47 packages hold.

There is no public root for this device: the MediaTek bootrom path used by `amonet`/`kamakiri` is
closed on MT8696.

## Sideloaded apps

`apps` installs three checksum-pinned APKs and aborts on mismatch. All are `armeabi-v7a` —
**this device is 32-bit** and rejects `arm64-v8a`.

| App | Package | Why |
| --- | --- | --- |
| TV Bro 2.1.6 | `com.phlox.tvwebbrowser` | D-pad browser replacing Silk; the `geckoExcluded` build is 6.8 MB against 150 MB, and this device has 1.7 GB RAM |
| Obtainium 1.6.10 | `dev.imranr.obtainium` | Installs and updates apps from GitHub releases |
| F-Droid | `org.fdroid.fdroid` | FOSS repository |
| Mullvad 2026.8 | `net.mullvad.mullvadvpn` | VPN, with a proper leanback icon |

F-Droid declares `LAUNCHER` but not `LEANBACK_LAUNCHER`. Fire OS lists it under Your Apps &
Channels anyway — unlike stock Android TV, which hides non-leanback apps entirely. Use
`./firetweak.sh launch <package>` if something does not show up.

**Private DNS keeps working inside the tunnel.** Measured with Mullvad connected: `dumpsys
connectivity` reports `UsePrivateDns: true` on both `wlan0` and `tun0`, and the resolver kept
receiving and filtering queries from the device throughout. The denylist above therefore still
applies while the VPN is up — the profile is matched on the DoT hostname, not on source IP.

The flip side is that the tunnel does not hide DNS from the resolver: queries made while connected
are still attributed to your profile and logged there.

## Playback safety

`KEEP` in `firetweak.sh` is a hard-coded list — DRM, account and licensing services, remote input,
streaming apps — that is never disabled regardless of what `packages.conf` says. Editing the config
cannot break playback.

`verify` checks the DRM services, the `widevine`/`playready`/`hdcp1` flags, that nothing in `KEEP`
is disabled, that disabled packages stayed disabled, that settings held, and that the home screen
resolves. `--deep` also launches each installed streaming app; it takes over the TV.

Playback itself was confirmed by hand on the reference device after the full debloat, `perf`, and
the switch to DNS-over-TLS. `verify` cannot prove that on its own — it shows the DRM flags are
advertised, not that a licence was fetched.

## Why not an existing tool

`firestrip`, `Fire-Scripts-CLI`, `firestick-loader` and `Fire-Tools` target `mantis`/`tank` on
Fire OS 6–7; their lists do not match `karat` on Fire OS 8. Running one blind is how Widevine gets
broken. Concrete example from building this: `com.amazon.firebat` uses 94 MB and looks like a
service worth killing — it is the Prime Video app.

The logic is `pm disable-user` in a loop. The value is the curated list, and that has to come from
your device.

## Layout

```text
firetweak.sh     the tool
test.sh          self-test for the parsing logic; no device required
packages.conf    tiered package list with rationale and measured memory figures
backups/
  state-*.txt    what was already disabled before the tool ran
  applied.txt    what the tool disabled; the exact input to `restore`
  settings.txt   every setting written, as `<namespace> <key> <applied> <original>`
```

## License

MIT — see [LICENSE](LICENSE).
