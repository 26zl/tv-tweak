# Sharp 4K UHDTV (Google TV)

Verified on **Sharp 4K UHDTV, MediaTek MT9676 (`maniatika`), Google TV on Android 14,
armeabi-v7a**. The package list comes from `pm list packages` on that device: 164 packages enabled
on a fresh set, 13 disabled by the default tiers.

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
there is no prompt at first.

The port stays armed across reboots. `service.adb.tcp.port` is not a persistent property and the
persistent variant is refused for the shell user, yet 37 seconds after an `adb reboot` on build
`UKN7.260716.012` port 5555 answered again, Wi-Fi off, with the property back at 5555; nothing in
the init scripts the shell user can read sets it. So the routine above is done once, and a reboot
does not close the port.

The authorisation does lapse. Android forgets an adb key that has not connected for seven days
(`adb_allowed_connection_time`, unset on this TV), and after two weeks without a connection the
TV put *Allow USB debugging?* on its screen at the next one. `tweak.sh` says so and waits
`TWEAK_TIMEOUT` seconds for it to be accepted with the remote; tick *Always allow from this
computer*. A key that connects every few days, as with `verify` on a timer, is not forgotten.

Port 5555 is plain, unencrypted ADB, advertised over mDNS: anything on the network can reach it,
and only the authorisation keeps it out. When you are done, run `./tweak.sh adb-off`, and turn USB
debugging back on when you next need the tool. Whether that alone brings port 5555 back, or the
wireless-debugging step has to be repeated, has not been tried.

`cmd wifi connect-network` is refused for the shell user on this production build (`forget-network`
is allowed), so joining a network goes through the TV's own settings; the rest is scriptable.

## Tiers

| Tier | Default | Effect |
| --- | --- | --- |
| `ads` | yes | Anoki ACR (fingerprints whatever is on screen), crash/usage uploaders, Privacy Sandbox, partner setup |
| `promo` | yes | Prime Video (so it is not on the keep list), Play Games, YouTube Music, retail demo |
| `ota` | no | Vendor firmware updater, which also delivers security fixes; Play and GMS updates are unaffected |
| `cruft` | yes | MHEG-5 |
| `assistant` | no | Voice search and Assistant stop working |
| `cast` | no | Chromecast built-in, DIAL and Miracast — phones can no longer cast |

`tune` turns window and transition animations off and location off.

Two things the firmware puts back at every boot, and the profile leaves them alone for that
reason: `mediatek.factorymenu.ui` re-enables the on-screen manual (`com.mtc.emanual`) about a
minute after boot, and `com.mediatek.tv.agent` writes `animator_duration_scale` back to 1.0 within
the first 40 seconds. Both were watched through a reboot on build `UKN7.260716.012`, with nothing
else touching the TV. An earlier version of this page put them down to a firmware update; an
update reboots the TV, and the reboot is enough. On a TV where an earlier version of the profile
disabled the manual or set the scale, `verify` reports both as given up instead of failing on
them, and `restore` clears the record.

The 15 other packages disabled on that set, by the default tiers and `ota`, were still off after
the same reboot. Run `verify` after reboots and updates all the same.

## Launcher

Google TV has no menu for changing the launcher, and the promo banner and recommendation rows
belong to the stock one. `apps` opens the Play listing for Projectivy Launcher — the install
itself needs the remote — and then:

```sh
./tweak.sh home com.spocky.projengmenu              # make it the preferred home screen
./tweak.sh home com.google.android.apps.tv.launcherx  # put the stock one back
```

`home` sets Android's preferred launcher, which Android follows only among launchers of equal HOME
priority; `set-home-activity` prints Success either way. So `home` then says where the Home button
actually goes, and `verify` checks that rather than the preference. If it is still the stock
launcher, Projectivy's own setting *Override current launcher* is what takes the button over: an
accessibility service, so Android keeps resolving Home to the stock launcher while the button
lands in Projectivy. `verify` accepts either launcher as a working home screen, and reports the
override as the working state once the service is on.

The stock launcher stays enabled (it is in `keep.conf`); it hosts system pieces beyond the home
screen. So does the setup wizard, `com.google.android.tungsten.setupwraith`, which also answers
Home. Guides that free Home for another launcher disable both, and on other Google TV 14 sets
[cleanyourtv](https://github.com/Gathin23/cleanyourtv/tree/main/examples) recorded what followed:
the Wi-Fi network saved during setup belongs to the wizard and was deleted with it (Sony BRAVIA 9
II), and with the stock launcher gone the wizard's recovery screen took Home and crash-looped the
system (Xiaomi TV A Pro 2026).

## Privacy settings that only exist in the UI

Not automated, worth a minute with the remote: Settings → Privacy → Ads (reset or delete the
advertising ID), Settings → Privacy → Usage & diagnostics (off), and Play Store → Settings →
Auto-update apps if you want updates to wait for you.

## Picture and sound

Not automated either, and `settings.conf` cannot carry them: nothing of the picture or the sound
output is in the `settings` tables. The picture values live in `com.mediatek.tv.agent`, whose
provider refuses the shell user, so the TV's own menus are the only way in. They open over
whatever input is on screen, where `uiautomator dump` still reads them and `screencap` does not:

```sh
adb shell am start -a android.settings.DISPLAY_SETTINGS            # Picture, for the input on screen
adb shell am start -a android.settings.oem.AUDIO_OUTPUT_SETTINGS   # Digital output, output device
adb shell am start -a android.settings.oem.SOUND_SETTINGS          # Sound style, speakers, eARC
```

Worth a look with a console on HDMI (checked with an Xbox Series S on build `UKN7.260716.012`):

- Picture → Advanced settings → *Enhanced viewing angle* is on by default. The driver calls it
  VAC, viewing-angle compensation: it trades contrast seen head-on for the view from the side, so
  a seat in front of the screen is better off without it. Switching it off does not outlast a
  reboot: at the one reboot this was watched through, the panel driver came up with it on again.
- Picture values are kept per source and per signal type, so SDR, HDR10 and Dolby Vision each
  have a picture mode of their own, a *Game* one among them. HDR10 from the console came up in
  *Movie*. Low latency follows ALLM whatever the mode.
- Advanced settings → *Refresh rate* is a frame-rate counter on the screen, not a setting.
- *Digital output* refuses to change while *Dolby Audio processing* is on, and that switch is
  greyed out while the output device is optical. Over optical the TV sends stereo PCM at a fixed
  level: the volume number on its screen changes nothing, and a soundbar that has learned the
  remote does the work.

## Sideloaded apps

| App | Package | Why |
| --- | --- | --- |
| TV Bro 2.1.6 | `com.phlox.tvwebbrowser` | D-pad browser; the `geckoExcluded` build is 6.8 MB against 150 MB |
| Obtainium 1.7.4 | `dev.imranr.obtainium` | Installs and updates apps from GitHub releases |
| F-Droid | `org.fdroid.fdroid` | FOSS repository; no leanback icon, use `launch` |
| Mullvad 2026.12 | `net.mullvad.mullvadvpn` | VPN, with a proper leanback icon |
| SmartTube 32.71 | `org.smarttube.stable` | Optional, installed only by `./tweak.sh apps org.smarttube.stable`: YouTube without ads, which YouTube says breaks its Terms of Service; see the note in `apps.conf` |
| Kodi 21.3 | `org.xbmc.kodi` | Media centre; the pinned checksum matches the one Kodi publishes |
| Projectivy Launcher | `com.spocky.projengmenu` | Ad-free launcher, from the Play Store |

## DNS

The TV honours Private DNS like any Android 14 device: `./tweak.sh dns <host>` sets it. If your
router forces DNS through its own resolver and rejects port 853 (OpenWrt's `https-dns-proxy`
does this by default), validation fails and the TV reports "No internet" — allow 853 for the TV's
address ahead of the reject rule, or leave DNS to the router. [docs/homelab.md](../../docs/homelab.md)
has the OpenWrt rule.
