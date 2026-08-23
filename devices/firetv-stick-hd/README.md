# Fire TV Stick 4K Max

Verified on **Fire TV Stick 4K Max (`karat` / `AFTKRT`), Fire OS 8.1.8.0, armeabi-v7a**. The
package list comes from `pm list packages` on that device, annotated with measured
`dumpsys meminfo` figures.

## ADB

Settings → My Fire TV → Developer Options → ADB debugging. The stick listens on port 5555 and
advertises itself over mDNS, so `tweak.sh` finds it without `DEVICE=` when it is the only device.
Accept the authorisation prompt on the TV the first time.

```sh
./tweak.sh --device firetv-stick-hd verify
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

`tune` turns animations off, sets `ota_disable_automatic_update`, and turns location off.

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
./tweak.sh dns your-profile.dns.nextdns.io
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

If your router forces DNS through its own resolver and rejects port 853 (OpenWrt's
`https-dns-proxy` does this by default), Private DNS fails validation, the stick reports
"No internet", and Android then refuses to auto-join that network at all. Allow 853 for the
stick's address ahead of the reject rule, or use `dns off` and filter at the router.

`com.amazon.vizzini` re-enables itself repeatedly, not once per boot — observed at 40 s, 275 s and
700 s of uptime within a single session, the last one right after an app was installed. `logcat`
shows `DeviceCapabilityServer` rebuilding the Alexa capability registry with `com.amazon.vizzini`
among its `owningPackages` each time, so package events look like a trigger; that is a hypothesis
from two coincidences, not a proven cause. Run `verify` after reboots *and* after installing
anything, and re-run `debloat alexa` when it reports drift. The other 47 packages hold.

There is no public root for this device: the MediaTek bootrom path used by `amonet`/`kamakiri` is
closed on MT8696.

## Sideloaded apps

All `armeabi-v7a` — **this device is 32-bit** and rejects `arm64-v8a`.

| App | Package | Why |
| --- | --- | --- |
| TV Bro 2.1.6 | `com.phlox.tvwebbrowser` | D-pad browser replacing Silk; the `geckoExcluded` build is 6.8 MB against 150 MB, and this device has 1.7 GB RAM |
| Obtainium 1.6.10 | `dev.imranr.obtainium` | Installs and updates apps from GitHub releases |
| F-Droid | `org.fdroid.fdroid` | FOSS repository |
| Mullvad 2026.8 | `net.mullvad.mullvadvpn` | VPN, with a proper leanback icon |

F-Droid declares `LAUNCHER` but not `LEANBACK_LAUNCHER`. Fire OS lists it under Your Apps &
Channels anyway — unlike stock Android TV, which hides non-leanback apps entirely. Use
`./tweak.sh launch <package>` if something does not show up.

**Private DNS keeps working inside the VPN tunnel.** Measured with Mullvad connected: `dumpsys
connectivity` reports `UsePrivateDns: true` on both `wlan0` and `tun0`, and the resolver kept
receiving and filtering queries from the device throughout. The denylist above therefore still
applies while the VPN is up — the profile is matched on the DoT hostname, not on source IP. The
flip side is that the tunnel does not hide DNS from the resolver: queries made while connected are
still attributed to your profile and logged there.

## Why not an existing tool

`firestrip`, `Fire-Scripts-CLI`, `firestick-loader` and `Fire-Tools` target `mantis`/`tank` on
Fire OS 6–7; their lists do not match `karat` on Fire OS 8. Running one blind is how Widevine gets
broken.
