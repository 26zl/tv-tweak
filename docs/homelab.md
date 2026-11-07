# tv-tweak in a homelab

The tool changes the TV; the network around it decides whether those changes hold and what else
can reach the TV. This page is what it took to run two of them behind an OpenWrt router with
Home Assistant beside them: a fixed address, a router that lets Private DNS through, ADB that is
off when nothing uses it, the right Home Assistant integration, `verify` on a timer, and a
segment of their own when that day comes. Addresses below are examples; use your reservations.

## A fixed address

Give each TV a DHCP reservation. The tool keys its state by the TV's serial number, so a new
address does not confuse it, but `DEVICE=`, the firewall rule below and Home Assistant all name
the address, and a lease that moves takes them all with it. A reservation inside the DHCP pool is
fine on dnsmasq: it never hands a reserved address to another MAC.

## Private DNS behind a router that forces DNS

`./tweak.sh dns <host>` sets Android's Private DNS, which is DNS-over-TLS on port 853. A router
that hijacks DNS so that every client uses its own resolver gets in the way: OpenWrt's
`https-dns-proxy` with `force_dns` redirects port 53 to itself and rejects 853 outright. Android
then validates the hostname, fails, and the result depends on the device: the Fire TV Stick says
"No internet" and refuses to auto-join the network, a set on Ethernet marks Private DNS broken and
quietly uses the router's resolver instead. `./tweak.sh dns show` tells you which it is:
`UsePrivateDns: true` with `ValidatedPrivateDnsAddresses` naming the resolver is the working state.

Exempt the TVs rather than the whole LAN. On OpenWrt that is one nftables rule
([`homelab/openwrt/allow-tv-dot.nft`](../homelab/openwrt/allow-tv-dot.nft)), copied to
`/etc/fw4-custom/` and loaded through `/etc/config/firewall`:

```text
config include
    option type 'nft'
    option path '/etc/fw4-custom/allow-tv-dot.nft'
    option position 'chain-pre'
    option chain 'forward_lan'
```

`position 'chain-pre'` is load-bearing: the reject is injected by `https-dns-proxy` through ubus
rather than written into the firewall config, so the only way to be evaluated before it is to be
at the top of the chain. `fw4 restart`, set Private DNS on the TV, and read the counter:

```sh
nft list chain inet fw4 forward_lan | grep 'tv private dns'    # non-zero once the TV has used it
```

The include is not part of any package, so a config restore that covers UCI alone leaves the file
behind. fw4 then loads the rest of the ruleset and logs `specifies unreachable path ... ignoring
section`, and the TVs keep working on the router's resolver: a silent change, which is why the
counter is worth a look now and then. On other firewalls the shape is the same: a rule that passes
TCP 853 from the TVs' addresses, placed above the DNS redirect.

The resolver is where the filtering happens. The Fire TV profile's README lists the update and
metrics domains to deny; `dns` points the TV at a resolver you control, which also means a Pi-hole
on plain port 53 is bypassed unless it is the one serving DoT.

## ADB on the network

Port 5555 is plain, unencrypted ADB, advertised over mDNS, and the authorisation prompt is the
only thing between the network and a shell on the TV. Turn it off when you are done
(`./tweak.sh adb-off`) and back on when you next need the tool; the Sharp's README has the
Ethernet routine, which needs repeating after every reboot. On a flat LAN the firewall cannot help,
because the switch forwards between the TV and everything else without asking the router; on a
VLAN of its own (below) the router admits 5555 from your workstation only.

A cheap check from the monitoring you already have: a TCP probe of 5555 on each TV that should be
closed. A port that answers when you did not arm it is worth an alert, and a Google TV set's 6466
answering is a sign the set is up.

## Home Assistant

The two verified devices need different integrations, and the ports say which:

| Port | Google TV (Sharp) | Fire TV Stick |
| --- | --- | --- |
| 5555, ADB | closed unless armed | open while ADB debugging is on |
| 6466 and 6467, Android TV Remote protocol | open | closed |
| 8009, Google Cast | open | closed |

- A Google TV set takes the **Android TV Remote** integration: it speaks Google's Remote Service,
  a pairing code appears on the screen, done. Cast is discovered on its own.
- A Fire TV Stick takes the **Android Debug Bridge** integration (device class *Fire TV*). Android
  TV Remote cannot work at any address, because Amazon strips Google's services out of Fire OS, and
  the failure is a bare "Failed to connect" that reads like a network problem and is not one. ADB
  debugging stays on for it, and the first connection raises the "Allow USB debugging?" prompt on
  the TV for Home Assistant's own key; until it is accepted the integration sits unauthorised.

The trap in one line: an address that refuses the connection is not necessarily offline, it may
not speak the protocol you picked. Probe the port before debugging the network. In Home Assistant
OS the established sockets are visible with `ss -tn state established` from the host shell
(`netstat` is not there, and an empty result from it looks like no connections); the ADB link is
opened on demand while the Remote link is persistent, so an idle stick shows nothing and is fine.

A stick that Home Assistant controls over ADB keeps port 5555 open for good. That is the one case
for the VLAN below, and the one TV `verify` can watch on a timer.

## verify on a timer

Firmware updates bring packages back and reset settings, and nobody runs `verify` on a Tuesday.
[`homelab/tv-verify.sh`](../homelab/tv-verify.sh) runs it against each TV named on the command
line and posts the FAIL and WARN lines to a webhook when any TV failed; a TV that does not answer
counts as failed, because a stick whose ADB went away has drifted too. It needs ADB reachable, so
it fits a TV whose ADB stays on anyway, not one you `adb-off`.

```sh
WEBHOOK_URL=https://discord.com/api/webhooks/... homelab/tv-verify.sh firetv-stick-4k-max-2023=192.0.2.11:5555
```

[`tv-verify.service`](../homelab/tv-verify.service) and [`tv-verify.timer`](../homelab/tv-verify.timer)
run it every morning as a user unit, because the TV authorised that user's adb key; the comments
in the service file are the install. A cron line on any always-on box does the same job.

## A segment of their own

A TV VLAN is the right place for a device that talks to advertisers for a living, and it is a
planning job, not a config change: Cast and the Remote protocol are found over mDNS, which does not
cross subnets without a reflector (`umdns` or avahi on the router), a wireless TV needs an SSID
mapped to the VLAN, and every device is paired again afterwards. The VLAN's rules are short:
the internet, 853 to the resolver, 5555 from your workstation, mDNS reflected to wherever Home
Assistant lives. Until then the two TVs sit on the flat LAN with Private DNS and ADB off, which is
the honest state of most homelabs.

## Updates

Keep firmware updates on; the `ota` tier is opt-in for a reason. Then expect them to undo some
of your work: one update on the Sharp brought back the on-screen manual and set
`animator_duration_scale` to 1.0 again. `verify` named both, `debloat cruft` and `tune` put them
back, and `verify` after every update, or the timer above, is what catches the next one.
