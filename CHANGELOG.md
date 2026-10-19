# Changelog

`./tweak.sh --version` prints the version. Versions follow [Semantic Versioning](https://semver.org/).

## Unreleased

## 0.1.0 — 2026-10-19

The first version with a number. Earlier states of `main` were unversioned.

### Changed — check these when you update

- **State moved out of the clone.** The undo record now lives per TV, in
  `~/.local/state/tv-tweak/<profile>/<serial>/` (`~/Library/Application Support/tv-tweak/…` on
  macOS, or `$TWEAK_STATE`). `backups/<profile>/` from earlier versions moves there the first time
  its TV is connected.
- **The Fire TV profile is now `firetv-stick-4k-max-2023`**, after the device it was made on; the
  old name `firetv-stick-hd` still works and its state moves along.
- **`ota` is no longer a default tier.** It stops security updates too; run `debloat ota` to keep
  blocking updates. On Fire TV, `ota_disable_automatic_update` moved from `tune` into that tier.
- **SmartTube is optional** on the Sharp profile: `./tweak.sh apps org.smarttube.stable`.
- **Environment variables** `PROFILE`, `CONF`, `MEDIA_APPS` and `BACKUP_ROOT` are now
  `TWEAK_PROFILE`, `TWEAK_CONF`, `TWEAK_MEDIA_APPS` and `TWEAK_STATE`. `BACKUP_DIR`,
  `SETTINGS_FILE` and `EXPECT_SERIAL` are gone; a second TV of the same model takes
  `--new-device` instead.
- `debloat`, `tune`, `apps` and `restore` exit 1 when anything failed, and say why.

### Added

- `--dry-run` for every command that changes something.
- `--version`; `-h`/`--help` anywhere on the line.
- `restore` puts back the launcher set with `home`; `restore --apps` removes what `apps` installed.
- `adb-off`, to turn ADB debugging off when you are done.
- `dns auto`, Android's default Private DNS mode.
- `apps <package>…`, and `optional` entries in `apps.conf`.
- A model guard: changes refuse a TV that is not the profile's device unless `--force` is given;
  another Android release, or a firmware update since the first backup, is a warning.
- A run log per TV, and an immutable baseline snapshot.
- `test-flows.sh`, which runs every command against a simulated TV in CI.
- `check-pins.sh` and a weekly `pins` workflow that compare the app pins with what each project
  publishes.
- When the TV is picked automatically, the tool says which one it used.

### Fixed

- `restore` deleted its record even when re-enabling a package or restoring a setting failed, and
  refused to roll settings back when no package had been recorded.
- `keep.conf` failed open: an entry followed by a comment, CRLF endings, a trailing space or a
  missing file left packages unprotected, and `pkg;` in `packages.conf` slipped past it.
- `<command> --help` ran the command; `dns --help` set the Private DNS hostname to `--help`.
- A failed read from the TV counted as an empty answer, so `verify` could print "ok" while a
  protected app was disabled.
- No adb call had a time limit; a setting's original could be lost when the connection dropped
  during a write, or when it contained spaces.
- `apps` re-downloaded and reinstalled every app on every run and stopped at the first failure;
  F-Droid's URL breaks once a newer version replaces it (now falls back to `archive/`).
- Unknown tiers, misplaced options and out-of-range `sleep` values were silently accepted.
- Starting `tweak.sh` through a symlink found no profiles.

### Security

- Arguments and profile values are validated before they reach the TV's shell; `device.conf` is
  read as data, no longer sourced.
- Downloads are HTTPS-only, redirects included, with time limits.
- App pins moved to Obtainium 1.6.17, Mullvad 2026.12 and SmartTube 32.56s, each checked against
  the digest its project publishes. TV Bro 2.1.6 is noted as still exposing the interface
  CVE-2023-43955 names.
