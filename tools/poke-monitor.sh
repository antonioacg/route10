#!/bin/sh
prev=""
while true; do
    car=$(cat /sys/class/net/eth4/carrier 2>/dev/null)
    if [ "$car" = "1" ]; then
        # re-enable MAC if disabled
        rx=$(printf "port rxmacstatus get 5\nquit\n" | ssdk_sh 2>&1 | awk -F: "/Value/{print \$2}" | tr -d " " | head -1)
        if [ "$rx" = "DISABLE" ]; then
            printf "port txmacstatus set 5 enable\nport rxmacstatus set 5 enable\nquit\n" | ssdk_sh >/dev/null
        fi
        out=$(curl -s --max-time 3 --interface 192.168.1.2 --user admin:admin "http://192.168.1.1/status_pon.asp" 2>&1)
        state=$(echo "$out" | grep -oE "O[0-9]" | head -1)
        tx=$(echo "$out" | sed -n "/Tx Power/,/dBm/p" | grep -oE "[-0-9.]+ +dBm|inf +dBm" | head -1 | tr -s " ")
        bias=$(echo "$out" | sed -n "/Bias/,/mA/p" | grep -oE "[0-9.]+ +mA" | head -1 | tr -s " ")
        summary="car=1 state=$state tx=$tx bias=$bias"
    else
        summary="car=0 (no link)"
    fi
    if [ "$summary" != "$prev" ]; then
        echo "$(date +%H:%M:%S) $summary"
        prev="$summary"
    fi
    sleep 2
done
