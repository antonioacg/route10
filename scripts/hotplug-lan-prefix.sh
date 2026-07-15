#!/bin/sh
# hotplug.d/iface hook — fire lan-prefix-track.sh the instant netifd reports an
# interface update, so a rotated-away LAN /64 is deprecated in ~1 s instead of
# waiting up to 60 s for the cron backstop. Event-plus-backstop, same shape as
# route-defaultroute-hook.sh (ip-up.d event + cron).
#
# The DHCPv6-PD prefix change lands as ACTION=ifupdate (a fresh PD on link-up is
# ifup) on the DHCPv6 interface (wan36) and/or the LAN it feeds (lan). We react to
# both, plus wan3, and let lan-prefix-track.sh's state-diff decide whether the GUA
# /64 actually rotated — a spurious call is a cheap no-op. The `* * * * *` cron
# stays the GUARANTEED backstop for any transition we don't catch instantly (e.g.
# an update that fires on wan36 before br-lan's new address settles).
#
# hotplug.d scripts are SOURCED by the dispatcher (the stock hooks here are not
# even +x), so bow out with `return` — a bare `exit` would abort the dispatcher
# and skip sibling hooks (mwan3, ddns, firewall...). `return || exit` covers being
# run either sourced or standalone. The tracker runs as a CHILD process so its own
# exit can never reach the dispatcher. Installed (symlinked into /etc/hotplug.d/
# iface/) each boot by post-cfg.sh — /etc is tmpfs on this box.
case "$ACTION"    in ifup|ifupdate) ;; *) return 0 2>/dev/null || exit 0 ;; esac
case "$INTERFACE" in lan|wan3|wan36) ;; *) return 0 2>/dev/null || exit 0 ;; esac
# One inline syslog line (same route10.prefix-track tag as the tracker) records
# that the event path fired even when no rotation is found. We do NOT source
# lib-observability.sh here: hotplug.d hooks are SOURCED, so defining its
# functions would leak into the dispatcher's shell and sibling hooks.
logger -t route10.prefix-track -p daemon.debug -- "hotplug $ACTION on $INTERFACE -> checking LAN prefix" 2>/dev/null
[ -x /cfg/scripts/lan-prefix-track.sh ] && /cfg/scripts/lan-prefix-track.sh
return 0 2>/dev/null || exit 0
