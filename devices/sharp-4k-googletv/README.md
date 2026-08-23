# Sharp 4K UHDTV (Google TV)

Verified on **Sharp 4K UHDTV, MediaTek MT9676 (`maniatika`), Google TV on Android 14,
armeabi-v7a**. The package list comes from `pm list packages` on that device: 164 packages enabled
on a fresh set, 16 disabled by the default tiers.

The TV is **32-bit** despite the 4K badge — `ro.product.cpu.abilist` is `armeabi-v7a,armeabi` —
so every sideload in `apps.conf` is a v7a build.

## ADB

Settings → System → About → select *Android TV OS build* seven times, then Settings → System →
Developer options → Wireless debugging. Pair once:

```sh
adb pair <ip>:<pairing-port> <code>      # from "Pair device with pairing code"
./tweak.sh --device sharp-4k-googletv verify
```

Android ties wireless debugging to Wi-Fi: it restarts on a new random port whenever Wi-Fi
reconnects or the TV reboots, and it refuses to turn on while the TV is on Ethernet only (the
toggle resets itself). The pairing survives; the port does not.

On Ethernet the working setup is plain TCP ADB: turn on *USB debugging* too (otherwise adbd stops
the moment wireless debugging goes away), and arm the port once from a wireless-debugging
session:

```sh
adb tcpip 5555          # while connected over wireless debugging
```

Then switch the TV to Ethernet (Settings → Network, Wi-Fi off), and `tweak.sh` finds it over
mDNS as `_adb._tcp` on port 5555. The pairing key doubles as the authorisation for port 5555, so
there is no prompt. The port lives in `service.adb.tcp.port`, which a reboot clears, and the
persistent variant is refused for the shell user — after a reboot, repeat: Wi-Fi on, wireless
debugging, `adb tcpip 5555`, Wi-Fi off.

`cmd wifi connect-network` is refused for the shell user on this production build (`forget-network`
is allowed), so joining a network goes through the TV's own settings; the rest is scriptable.

## Tiers

| Tier | Default | Effect |
| --- | --- | --- |
| `ads` | yes | Anoki ACR (fingerprints whatever is on screen), crash/usage uploaders, Privacy Sandbox, partner setup |
| `promo` | yes | Prime Video, Play Games, YouTube Music, retail demo |
| `ota` | yes | Vendor firmware updater; Play and GMS updates are unaffected |
| `cruft` | yes | On-screen manual, MHEG-5 |
| `assistant` | no | Voice search and Assistant stop working |
| `cast` | no | Chromecast built-in, DIAL and Miracast — phones can no longer cast |

`tune` turns animations off and location off. No Google TV package disabled here re-enables
itself; `verify` will tell you if that changes after an update.

## Launcher

Google TV has no menu for changing the launcher, and the promo banner and recommendation rows
belong to the stock one. `apps` opens the Play listing for Projectivy Launcher — the install
itself needs the remote — and then:

```sh
./tweak.sh home com.spocky.projengmenu              # make it the home screen
./tweak.sh home com.google.android.apps.tv.launcherx  # put the stock one back
```

`verify` accepts either as a working home screen. The stock launcher stays enabled (it is in
`keep.conf`); it hosts system pieces beyond the home screen.

## Privacy settings that only exist in the UI

Not automated, worth a minute with the remote: Settings → Privacy → Ads (reset or delete the
advertising ID), Settings → Privacy → Usage & diagnostics (off), and Play Store → Settings →
Auto-update apps if you want updates to wait for you.

## Sideloaded apps

| App | Package | Why |
| --- | --- | --- |
| TV Bro 2.1.6 | `com.phlox.tvwebbrowser` | D-pad browser; the `geckoExcluded` build is 6.8 MB against 150 MB |
| Obtainium 1.6.10 | `dev.imranr.obtainium` | Installs and updates apps from GitHub releases |
| F-Droid | `org.fdroid.fdroid` | FOSS repository; no leanback icon, use `launch` |
| Mullvad 2026.8 | `net.mullvad.mullvadvpn` | VPN, with a proper leanback icon |
| SmartTube 32.10 | `org.smarttube.stable` | YouTube without ads, built for a remote |
| Kodi 21.3 | `org.xbmc.kodi` | Media centre; the pinned checksum matches the one Kodi publishes |
| Projectivy Launcher | `com.spocky.projengmenu` | Ad-free launcher, from the Play Store |

## DNS

The TV honours Private DNS like any Android 14 device: `./tweak.sh dns <host>` sets it. If your
router forces DNS through its own resolver and rejects port 853 (OpenWrt's `https-dns-proxy`
does this by default), validation fails and the TV reports "No internet" — allow 853 for the TV's
address ahead of the reject rule, or leave DNS to the router.
