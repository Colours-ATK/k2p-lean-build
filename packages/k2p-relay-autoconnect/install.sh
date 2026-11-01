#!/bin/sh
# Install the ApCli AutoConnect helper on an OpenWrt router that runs the MTK
# closed-source Wi-Fi driver (mt7615d) as a wireless relay.
#
#   ./install.sh                install and apply now
#   ./install.sh --uninstall    remove it and disable the feature
#
# Safe to run on a plain AP: the helper only acts on relay configurations.
set -e

DEST=/etc/hotplug.d/iface/99-apcli-autoconnect
SRC=$(dirname "$0")/root/etc/hotplug.d/iface/99-apcli-autoconnect

if [ "$1" = "--uninstall" ]; then
	iwpriv apcli0 set ApCliAutoConnect=0 >/dev/null 2>&1 || true
	rm -f "$DEST"
	rm -f /tmp/.apcli-autoconnect.lock
	logger -t apcli-autoconnect "helper removed"
	echo "removed $DEST"
	exit 0
fi

mkdir -p "$(dirname "$DEST")"
cp "$SRC" "$DEST"
chmod 0755 "$DEST"
echo "installed $DEST"

# Apply now as well, so the feature does not need a reboot. The helper does the
# same thing on every boot, after the relay interface comes up.
relay=no
for f in /etc/wireless/mt7615/*.dat; do
	[ -f "$f" ] || continue
	grep -q '^ApCliEnable=1' "$f" || continue
	grep -qE '^ApCliSsid=.+' "$f" || continue
	relay=yes
	break
done

if [ "$relay" != yes ]; then
	echo "not a relay configuration; the helper will stay idle"
	exit 0
fi

if iwpriv ra0 set MACRepeaterEn=1 >/dev/null 2>&1 &&
   iwpriv apcli0 set ApCliAutoConnect=1 >/dev/null 2>&1; then
	logger -t apcli-autoconnect "ApCliAutoConnect enabled on apcli0"
	echo "enabled on apcli0 (the relay link drops for a few seconds)"
else
	echo "WARNING: could not enable the feature; check that the relay is associated" >&2
	exit 1
fi
