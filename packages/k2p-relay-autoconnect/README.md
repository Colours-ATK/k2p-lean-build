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
* recommended: `patches/0002-mt7615d-apcli-autoconnect-idempotent.patch`
  (see below). Without it the helper still works, but loses the feature after a
  driver reload.

## Driver patch: why the setter has to be idempotent

`AutoConnectFlag` lives in the driver. It has **no profile key and no
read-back** — `Set_ApCli_AutoConnect_Proc()` is a setter only — and it is reset
whenever the driver is reloaded (`wifi reload`, `mtkwifi restart`, …). A
one-shot "armed once per boot" flag therefore goes stale: the flag is gone but
the helper thinks it already did its job.

So the helper re-arms on every `ifup`. That is only safe when the setter is
idempotent. Stock MTK 5.0.4.0 is not: every call runs `Set_ApCli_Enable("0")`
and drops `apcli0`.

`patches/0002-mt7615d-apcli-autoconnect-idempotent.patch` adds

```c
/* "1" means ensure, not force: keep an already armed link up. */
if (scan_mode == 1 && pApCfg->ApCliTab[ifIndex].AutoConnectFlag == TRUE)
	return TRUE;
```

before the scan-in-progress check, so value `1` becomes idempotent while `2`
keeps the old "force a rescan" meaning.

The patch logs `ApCliAutoConnect already armed, keep link up`. The helper greps
the module for that string as a capability probe:

| driver | helper behaviour |
|---|---|
| patched | re-arms on every `ifup`; survives `wifi reload` and `mtkwifi restart` |
| stock | falls back to arming once per boot (the old behaviour) |

That keeps the package safe to install on a stock Lean tree: it can never turn
into a link drop on every `ifup`.

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

The handler itself only does cheap checks (relay profile, driver capability) and
returns. The work runs in a background worker so netifd is never blocked:

1. take a `flock` slot (concurrency only),
2. on a stock driver: skip if this boot already armed the flag,
3. wait a few seconds for the interface to settle,
4. enable `MACRepeaterEn`,
5. warn if `MACRepeaterOuiMode` is not `2`,
6. enable `ApCliAutoConnect`, retrying because the driver refuses to change the
   setting while a scan is running.

### Loop safety

Enabling AutoConnect deliberately drops `apcli0`, so netifd raises `ifdown` and
later `ifup` again. With the idempotent setter that second call returns without
touching the link, so the re-entry terminates on its own.

The `flock` in step 1 is **not** a one-shot guard: it is released as soon as the
worker exits (or is killed), so it can never leave a stale lock that blocks a
later re-arm. `/tmp/.apcli-autoconnect.once` is only used on stock drivers.

## Verify

```sh
# is the setter idempotent on this device?
grep -qa 'ApCliAutoConnect already armed' /lib/modules/$(uname -r)/mt_wifi.ko \
	&& echo patched || echo stock

# applied?
logread | grep apcli-autoconnect
ls -l /tmp/.apcli-autoconnect.*

# survives a driver reload? (patched driver only)
wifi reload
sleep 20
logread | grep apcli-autoconnect | tail -1     # a new "ensured" line

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
apcli-autoconnect: ApCliAutoConnect ensured on apcli0 (attempt 1, idempotent=yes)
apcli-autoconnect: ApCliAutoConnect ensured on apcli0 (attempt 1, idempotent=no)
apcli-autoconnect: not a relay configuration (no ApCliEnable=1 with an upstream SSID), skipping
```

## Caveats

* The **first** arm after boot drops the relay link once (about 5–15 s). With a
  patched driver later `ifup`s are no-ops, so this happens once per boot, not
  once per event.
* On a **stock** driver the feature is lost after `wifi reload`/`mtkwifi
  restart` until the next reboot; apply the patch to avoid that.
* While the link is down the driver scans all channels once per second, briefly
  occupying airtime that the local AP would otherwise use.
* It only helps with **channel changes of the upstream AP**. It does not raise
  the throughput ceiling, which is set by the shared radio: the AP and the STA
  side cannot transmit at the same time.
* `MACRepeaterEn` is applied at runtime, so an external `wifi reload` resets it;
  the handler re-applies it on the next `ifup`.

## Files

```
packages/k2p-relay-autoconnect/
  root/etc/hotplug.d/iface/99-apcli-autoconnect   netifd hotplug handler
  install.sh                                      install / uninstall
  README.md

patches/                                          (repository root)
  0001-mt7615d-apcli-edca-cwmin.patch             optional EDCA override key
  0002-mt7615d-apcli-autoconnect-idempotent.patch ap_cfg.c: make "=1" idempotent
```
