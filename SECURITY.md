# Security policy

## Reporting a vulnerability

Report it privately on GitHub: **Security → Report a vulnerability** in this repository. Please do
not open a public issue for it.

Include the version (`./tweak.sh --version`, or the commit), the profile, and how to reproduce it.
Leave out serial numbers, IP addresses and DNS hostnames.

## Scope

In scope: `tweak.sh`, the profiles (package, keep and settings lists) and the pinned entries in
`apps.conf`, such as a wrong URL or checksum. A vulnerability in one of the apps themselves belongs
with its project; a known problem with a pinned version is noted next to its entry, as for TV Bro
and CVE-2023-43955.

## Supported versions

The latest release and `main`. This is a one-person project maintained on a best-effort basis.
