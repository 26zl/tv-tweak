# Contributing

Issues and pull requests are welcome. For a security problem, see [SECURITY.md](SECURITY.md)
instead.

## Before a pull request

```sh
./test.sh && ./test-flows.sh && shellcheck tweak.sh test.sh test-flows.sh check-pins.sh
```

None of these needs a device. CI runs them on Linux and macOS; keep them green.

- POSIX `sh` only; it must run under dash, `bash --posix` and busybox sh, and on macOS.
- Keep the existing style: four-space indent, comments that explain why. There is no formatter.
- A change in behaviour comes with a case in `test-flows.sh`, a bug fix with a regression test.
- Add a line to [CHANGELOG.md](CHANGELOG.md) under "Unreleased".

## Adding a device

A profile is code: its lists decide what is disabled on someone's TV, and a list copied from
another device is how playback breaks. Build it from the device itself.

1. On the device: `adb shell pm list packages` (and `-d`, `-3`), `getprop ro.product.model`,
   `ro.product.device` and `ro.build.version.release`.
2. `devices/<profile>/device.conf`: the exact model and device codename, default tiers, the
   launchers that count as a working home screen, the streaming apps, the DRM props, and the
   Android release.
3. `keep.conf`: the launcher, input stack, remote pairing, DRM services, account and Play or
   Amazon services, and every streaming app. The tool refuses to run without it.
4. `packages.conf`: `<tier> <package>` lines, each with a reason, opt-in tiers for anything with a
   real trade-off (voice, casting, updates).
5. On the device, in this order: `verify`, `debloat --dry-run`, `debloat`, `tune`, `verify`, play
   something with DRM (Netflix, Prime Video), `restore`, `verify`.
6. `devices/<profile>/README.md`: what was verified, on which firmware, and the device's quirks.

To change an app pin, take the checksum from the digest the project publishes, note the date in
`apps.conf`, and run `./check-pins.sh`; the `pins` workflow runs it weekly too.

Leave out serial numbers, IP addresses and DNS hostnames from logs you paste anywhere.
