# AGENTS.md

tv-tweak is one POSIX `sh` script, `tweak.sh`, that debloats and tunes Fire TV and Google TV
devices over ADB, with everything device-specific in `devices/<profile>/`. The README says what each
command does.

## Commands

Run from the repository root. None of these touches a device or the network.

- `./test.sh`: profile parsing and the shape of every shipped profile.
- `./test-flows.sh`: every command end to end against a simulated TV (a fake adb in a temporary
  directory); takes about half a minute.
- `shellcheck tweak.sh test.sh test-flows.sh check-pins.sh`: must be clean.
- `sh -n tweak.sh`, and the same with `dash -n` and `busybox sh -n` where available.

CI (`.github/workflows/ci.yml`) runs all of them on ubuntu-latest and macos-latest.

`./check-pins.sh` is the exception: it compares the `apps.conf` pins with what each project
publishes, so it needs the network and `gh`. The `pins` workflow runs it weekly and whenever a pin
changes.

## Structure

- `tweak.sh`: validators (`is_tok`, `is_pkg`, `is_host`, `q`), the profile reader (`conf_lines`,
  `read_device_conf`, `check_file`), adb helpers (`sh_`, `dev`, `pkg_list`, `timed`), per-TV
  state (`load_state`, `migrate_legacy`), one `cmd_<name>` function per command, and the
  dispatcher at the end.
- `devices/<profile>/`: `device.conf` (key="value" data, never executed), `packages.conf`
  (`<tier> <package>`), `keep.conf`, `apps.conf`, `settings.conf`, and a `README.md` saying what was
  verified.
- `test.sh` sources tweak.sh with `TWEAK_LIB=1`; `test-flows.sh` builds its fake adb and TV itself.

## Conventions

- POSIX `sh` only: no arrays, `local`, `[[ ]]` or other bashisms; it must pass under dash,
  `bash --posix` and busybox sh, on Linux and on macOS's BSD userland (no `sed -i`).
- Four-space indent and the existing compact style; there is no formatter. Comments say why.
- Every value that reaches `adb shell` passes `is_tok`, `is_pkg` or `is_host`, or is quoted with `q`:
  adb joins its arguments with spaces and the TV's shell parses the result.
- Reads from the TV go through `dev` or `pkg_list`, which fail rather than return empty output.
- A change in behaviour comes with a case in `test-flows.sh` (`test.sh` for parsing), and a bug
  fix with a regression test that fails without it.
- British spelling in comments and messages; commit messages in the imperative, saying why.

## Boundaries

- Never run `tweak.sh` against a real TV unless the owner asks for it in the session; `ADB` and
  `DEVICE` decide what is touched, and the tests use their own fake.
- Never commit a state directory or `backups/`, and never copy serial numbers, IP addresses or DNS
  hostnames from a real device into the repository.
- Profile changes are code changes. A package list comes from `pm list packages` on the device it
  names, never from another device; `keep.conf` keeps the launcher, input stack, DRM services and
  streaming apps.
- An APK pin is taken from the digest its project publishes (a GitHub release asset's `digest`,
  Kodi's `.sha256`, F-Droid's index), with the date noted in `apps.conf`.
- Ask before adding a dependency beyond adb, curl and POSIX tools.

## Domain notes

- `restore` works only from the per-TV state (`applied.txt`, `settings.txt`, `home.txt`,
  `apps.txt`, `baseline.txt`) and keeps whatever it could not undo; that record must never be lost.
- `settings.txt` keeps originals shell-quoted, `null` for unset; bare tokens from older versions are
  still read.
- A `settings.conf` line with a fourth column belongs to that tier and is applied by
  `debloat <tier>`. The `ota` tier is opt-in because it stops security updates.
- `home` sets a preferred activity, which Android ignores while a launcher with a higher HOME
  priority is enabled (Fire OS, Google TV); `set-home-activity` prints Success either way.
  `home_resolved` is where Home goes and what `verify` checks; `home_activity` is what `restore`
  records and puts back.
- macOS's Local Network privacy turns away a program it has not allowed with "No route to host",
  and the adb server keeps the permission of the app that started it.

## Pitfalls

- `set -e` is off inside functions called from `if`, `!`, `&&` or `||`; check status explicitly.
- After `fi`, `$?` is 0 when no branch ran; capture it in the `else` branch.
- dash skips the EXIT trap on a signal, so the INT/TERM/HUP trap calls `exit` to reach `on_exit`.
- `sort` and `comm` must use the same collation: `LC_ALL=C` when comparing sorted lists.
- `timeout` may be killed by its own signal (exit 143): `reason` treats 124, 137, 142 and 143 as a
  timeout.
