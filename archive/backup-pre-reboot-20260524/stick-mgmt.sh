#!/bin/sh
# Break-glass mgmt access to the stick (ODI DFP-34X) at 192.168.1.1.
# W2-ONLY since 2026-05-24 — L4 is now a 10G BiDi SFP+ to the office switch
# (part of br-lan/br-lan_2/br-lan_7) and MUST NOT be reconfigured.
#
# Background: Alta's `route-swd` polls SFP every ~15s and re-applies port
# mode, bouncing the SerDes lane. pppd's PADI retry loop on a failing
# PPPoE WAN does the same on eth4. Both prevent stable mgmt access.
# This script stops them, configures L3+firewall path on W2, and `off` reverts.
#
# Usage:
#   /cfg/scripts/stick-mgmt.sh on      — enable mgmt path to stick in W2
#   /cfg/scripts/stick-mgmt.sh off     — revert: restart route-swd+wan*, clean rules
#   /cfg/scripts/stick-mgmt.sh status  — show current state
#
# Install to /cfg/scripts/ (ext4-backed, survives reboot). Not auto-invoked.

MGMT_IP=192.168.1.2/24
HOST_ROUTE=192.168.1.1/32
MGMT_NET=192.168.1.0/24
STICK_IP=192.168.1.1

ssdk() { printf '%s\nquit\n' "$1" | ssdk_sh 2>&1 | grep -vE 'SSDK Init|Welcome|^dev0|^$|^quit'; }

w2_present() {
    # Physical presence: i2c bus 1 0x50 EEPROM readable. (Host-side enable
    # state and carrier are downstream signals and DISABLE/0 is normal until
    # we configure port 5 ourselves.)
    i2cget -y 1 0x50 0x00 b >/dev/null 2>&1 && return 0
    # Fallbacks (legacy):
    p5=$(ssdk 'port linkstatus get 5' | awk -F: '/Status/{print $2}' | tr -d ' ' | head -1)
    [ "$p5" = "ENABLE" ] && return 0
    [ "$(cat /sys/class/net/eth4/carrier 2>/dev/null)" = "1" ] && return 0
    return 1
}

stop_flap_sources() {
    /etc/init.d/route-swd stop 2>/dev/null
    # Stop whichever WAN may be cycling pppd PADIs. WAN1 (eth3) is the
    # Huawei path — leaving it up keeps our internet during stick mgmt.
    ifdown wan2 2>/dev/null
    ifdown wan3 2>/dev/null
    # Re-enable MAC TX/RX on W2 only (route-swd may have disabled them).
    # DO NOT touch port 6 — that's the office switch BiDi.
    ssdk 'port txmacstatus set 5 enable' >/dev/null
    ssdk 'port rxmacstatus set 5 enable' >/dev/null
}

restart_normal() {
    /etc/init.d/route-swd start 2>/dev/null
    ifup wan2 2>/dev/null
    ifup wan3 2>/dev/null
}

remove_w2_setup() {
    ip addr del "$MGMT_IP" dev eth4 2>/dev/null
    ip route del "$HOST_ROUTE" dev eth4 2>/dev/null
    iptables -t nat -D POSTROUTING ! -s "$MGMT_NET" -o eth4 -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -i eth4 -s "$MGMT_NET" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -o eth4 -d "$MGMT_NET" -j ACCEPT 2>/dev/null
    iptables -D INPUT  -i eth4 -s "$MGMT_NET" -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -o eth4 -d "$MGMT_NET" -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -o eth4 -s "$MGMT_NET" -j ACCEPT 2>/dev/null
}

setup_w2() {
    ssdk 'port interfaceMode set 5 sgmii_fiber' >/dev/null
    ssdk 'port interfaceMode apply 5' >/dev/null
    ip link set eth4 up
    ip addr show dev eth4 | grep -q '192.168.1.2/24' || ip addr add "$MGMT_IP" dev eth4
    ip route replace "$HOST_ROUTE" dev eth4
    iptables -t nat -C POSTROUTING ! -s "$MGMT_NET" -o eth4 -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING ! -s "$MGMT_NET" -o eth4 -j MASQUERADE
    # Punch firewall holes (eth4 is in WAN zone, default-deny)
    for rule in \
        "FORWARD -i eth4 -s $MGMT_NET -j ACCEPT" \
        "FORWARD -o eth4 -d $MGMT_NET -j ACCEPT" \
        "INPUT  -i eth4 -s $MGMT_NET -j ACCEPT" \
        "OUTPUT -o eth4 -d $MGMT_NET -j ACCEPT" \
        "OUTPUT -o eth4 -s $MGMT_NET -j ACCEPT"; do
        # shellcheck disable=SC2086
        iptables -C $rule 2>/dev/null || iptables -I $rule
    done
}

reachable() {
    ping -c 1 -W 2 -I 192.168.1.2 "$STICK_IP" >/dev/null 2>&1
}

case "$1" in
    on|w2|"")
        if ! w2_present; then
            echo "No SFP module detected in W2 (eth4 carrier down, ssdk port 5 not ENABLE)."
            echo "Insert the ODI stick into the W2 cage and retry."
            echo "(L4 is the office switch BiDi — never put the GPON stick there.)"
            exit 1
        fi
        echo "Stick detected in W2. Setting up mgmt + stabilizing link..."
        stop_flap_sources
        setup_w2
        sleep 2
        if reachable; then
            echo "OK — stick UI: http://$STICK_IP"
        else
            echo "Setup done but stick not yet responding. Wait 5-10s and retry, or:"
            echo "  - check fiber/host seating"
            echo "  - $0 status   to inspect"
        fi
        ;;
    off)
        echo "Reverting to normal Alta operation..."
        remove_w2_setup
        restart_normal
        echo "Done. route-swd and wan2/wan3 restarted; manual mgmt path removed."
        echo "(WAN1 PPPoE on eth3 was left running throughout.)"
        ;;
    status)
        echo "=== services ==="
        ps w | grep -E 'route-swd|pppd' | grep -v grep || echo "  route-swd/pppd: NOT running"
        echo "=== W2 cage ==="
        ssdk 'port linkstatus get 5'
        ssdk 'port interfaceMode get 5'
        echo "  eth4 carrier: $(cat /sys/class/net/eth4/carrier 2>/dev/null)"
        echo "=== aliases ==="
        ip -br addr show eth4 | head
        echo "=== host route ==="
        ip route show 192.168.1.1 || echo "(none)"
        echo "=== NAT (192.168.1.0/24 outbound) ==="
        iptables -t nat -S POSTROUTING | grep "192.168.1" || echo "(none)"
        echo "=== firewall punches for 192.168.1.0/24 on eth4 ==="
        iptables -S | grep "192.168.1" || echo "(none)"
        echo "=== reachability ==="
        reachable && echo "  http://$STICK_IP: REACHABLE" || echo "  http://$STICK_IP: no response"
        ;;
    l4)
        echo "REFUSED: port 6 / eth5 / L4 is the office switch 10G BiDi."
        echo "Reconfiguring it would take the office offline."
        exit 2
        ;;
    *)
        echo "Usage: $0 [on|off|status]"
        exit 1
        ;;
esac
