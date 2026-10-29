#!/bin/sh /etc/rc.common

chmod 0755 /sbin/mtkwifi

# Must start after S20network: br-lan is created by netifd, and an earlier
# start makes the bridge addif in mt7615_up() fail silently.
START=40
STOP=15

USE_PROCD=1

start_service() {
	[ -f /etc/hotplug.d/firmware/11-mtk-wifi-e2p ] && sh /etc/hotplug.d/firmware/11-mtk-wifi-e2p
	# This Lean tree ships no boot hook that calls wifi up, and the no-argument
	# form of mtkwifi crashes on a device entry without init_compatible, so
	# bring each parsed device up by name. mt7615_up() also bridges the
	# interfaces into br-lan.
	for d in $(lua -e 'package.path="/usr/lib/lua/?.lua;"..package.path; local ok,m=pcall(require,"mtkwifi"); if not ok then return end; for k in pairs(m.search_dev_and_profile()) do io.write(k," ") end' 2>/dev/null); do
		/sbin/mtkwifi up "$d" >/dev/null 2>&1
	done
}

stop_service() {
    echo 'do nothing' > /dev/null
}
