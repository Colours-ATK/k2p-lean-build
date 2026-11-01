# k2p-relay-autoconnect

Make a K2P (MT7621 + mt7615d, closed-source MTK driver) **wireless relay**
recover automatically when the upstream AP changes channel.

Relay only: in plain AP mode there is nothing to recover, so the helper does
nothing there.

## The problem

The relay's STA side (`apcli0`) and the local AP share **one radio**, so both
must sit on the same channel. The local AP channel is a static startup value
(`Channel=` in `/etc/wireless/mt7615/mt7615.1.5G.dat`).

When the upstream AP is moved to another channel:

* `apcli0` disassociates:
  `!!! APCLI LINK DOWN - IF(apcli0) (Reason=send deauth req,sub=apcli if down)`
* the driver cannot re-derive the shared channel on its own
* the relay stays down until the profile is edited and the radio reloaded

## The fix

The driver already implements the missing behaviour, it is just not enabled:

```sh
iwpriv ra0 set MACRepeaterEn=1        # repeater mode (reconnection check gate)
iwpriv apcli0 set ApCliAutoConnect=1  # scan upstream every second, follow it
```

With that, once the link is down the driver scans for the upstream SSID every
second (`ApCliAutoConnectExec` → `ApCliSwitchCandidateAP`) and re-applies the
channel it found to the whole band. Because the AP and the STA side share one
radio, the local AP follows and the relay comes back on its own.

Both are **runtime ioctls**. Nothing in the profile is modified, so a plain AP
setup and the next boot are unaffected.

### Measured on K2P A2

OpenWrt 24.10.5, Linux 5.10.272, MTK driver 5.0.4.0. The local AP was forced to
a different channel than the upstream while the relay was running:

| time | state |
|---|---|
| +5 s | AP and STA both on the forced channel, `apcli0` down |
| +20 s | `apcli0` associated again, band pulled back to the upstream channel |
| +25 s | default route restored |
| +25…+60 s | stable |

Without `ApCliAutoConnect` the same test leaves the relay down indefinitely.

## Requirements

* MTK closed-source Wi-Fi driver (`kmod-mt7615d`, `mt_wifi` 5.0.4.0)
* a relay configuration in the wireless profile:

  ```
  ApCliEnable=1
  ApCliSsid=<upstream ssid>
  ```

  The helper checks for exactly this and exits otherwise.
* `MACRepeaterOuiMode=2` in the same profile. This one has **no runtime ioctl**
  and is read when the driver starts; the stock Lean profile already ships `2`.
  The helper logs a warning if it is not `2`.

## Install

```sh
./install.sh                    # copies the hotplug handler into place
iwpriv ra0 set MACRepeaterEn=1
iwpriv apcli0 set ApCliAutoConnect=1   # apply now, without a reboot
```

The handler then re-applies everything on the next boot.

## Uninstall

```sh
./install.sh --uninstall
iwpriv apcli0 set ApCliAutoConnect=0
```

## How it works

`root/etc/hotplug.d/iface/99-apcli-autoconnect` is a netifd interface hotplug
handler. It acts on `ACTION=ifup` with `INTERFACE=apcli`, i.e. when the relay
interface has just come up.

It never blocks netifd: the handler claims a lock file synchronously and then
backgrounds a worker that

1. waits until `apcli0` is really associated with the upstream,
2. enables `MACRepeaterEn`,
3. warns if `MACRepeaterOuiMode` is not `2` in the profile,
4. waits a few seconds for the link to settle,
5. enables `ApCliAutoConnect`.

### Why the lock file is required

Enabling AutoConnect deliberately drops `apcli0`. netifd then raises `ifdown`
and later `ifup` for the same interface, so a handler that sets the flag on
every `ifup` would keep triggering itself. The lock file is created before the
worker is backgrounded, so exactly one worker runs per boot. It lives in `/tmp`
(tmpfs) and is therefore cleared on reboot. If the worker cannot find the
upstream within 60 s it removes the lock so a later event can retry.

## Verify

```sh
# applied?
logread | grep apcli-autoconnect
ls -l /tmp/.apcli-autoconnect.lock

# scanning while the link is down
dmesg | grep -i 'scan(1)' | tail

# forced channel change: the relay must come back on its own
iwpriv ra0 set Channel=153
watch -n2 'iwconfig apcli0 | grep -oE "Frequency=[0-9.]+"; ip route | grep default'
# restore
iwpriv ra0 set Channel=149
```

Expected log lines:

```
apcli-autoconnect: ApCliAutoConnect enabled on apcli0
apcli-autoconnect: not a relay configuration (no ApCliEnable=1 with an upstream SSID), skipping
```

## Caveats

* Enabling the flag **drops the relay link once** (about 5–15 s). Doing it while
  traffic is flowing interrupts that traffic.
* While the link is down the driver scans all channels once per second, briefly
  occupying airtime that the local AP would otherwise use.
* It only helps with **channel changes of the upstream AP**. It does not raise
  the throughput ceiling, which is set by the shared radio: the AP and the STA
  side cannot transmit at the same time.
* `MACRepeaterEn` is applied at runtime, so an external `wifi reload` resets it;
  the handler re-applies it on the next `ifup`.

## Files

```
root/etc/hotplug.d/iface/99-apcli-autoconnect   netifd hotplug handler
install.sh                                      install / uninstall
```
