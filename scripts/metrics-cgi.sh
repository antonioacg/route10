#!/bin/sh
# metrics-cgi.sh — Prometheus text exposition for route10 (spec: seam mail #103).
#
# Contract: ops NETWORK-CONTRACT.md "route10 metrics scrape (:9100)" (drafted
# 1839954, confirmed via seam mail — the endpoint is a shared value). Deploy:
#   scp -> /cfg/scripts/metrics-www/metrics  (chmod +x)
#   uhttpd -p 192.168.10.1:9100 -h /cfg/scripts/metrics-www -x /metrics
#     (LAN-only bind; relaunched each boot by post-cfg)
#
# Design: serves from data that already exists — the newest /a/stats.sql minute
# (Alta rcstats) and the newest /a/obs/rt.sql sample (obs-collect.sh). NO live
# probing from the request path: no i2c, no Boa, no stick telnet, no ubus. A
# scrape can never perturb the box; staleness is exposed as *_timestamp_seconds
# so the scraper alerts on it instead of us lying with old numbers.
# Both DBs are opened read-only with a busy timeout.
#
# The scrape is trending/slow-degradation telemetry ONLY — it is pull over the
# LAN and dies with it. The unconditional /cfg + /a records are the outage
# telemetry. (Contract framing agreed in seam mail #101/#103.)

printf 'Content-Type: text/plain; version=0.0.4\r\n\r\n'

q() { sqlite3 -readonly -init /dev/null -cmd ".timeout 3000" "$1" "$2" 2>/dev/null; }

# ── Alta rcstats: newest minute ─────────────────────────────────────────────
q "file:/a/stats.sql?mode=ro" "
SELECT
  'route10_stats_minute_timestamp_seconds ' || ts || char(10) ||
  'route10_load{stat=\"min\"} '  || json_extract(json,'\$.load.<') || char(10) ||
  'route10_load{stat=\"avg\"} '  || json_extract(json,'\$.load.a') || char(10) ||
  'route10_load{stat=\"max\"} '  || json_extract(json,'\$.load.>') || char(10) ||
  'route10_mem_used_ratio{stat=\"min\"} ' || json_extract(json,'\$.mem.<') || char(10) ||
  'route10_mem_used_ratio{stat=\"avg\"} ' || json_extract(json,'\$.mem.a') || char(10) ||
  'route10_mem_used_ratio{stat=\"max\"} ' || json_extract(json,'\$.mem.>') || char(10) ||
  'route10_temp_celsius{stat=\"min\"} '   || json_extract(json,'\$.temp.<') || char(10) ||
  'route10_temp_celsius{stat=\"avg\"} '   || json_extract(json,'\$.temp.a') || char(10) ||
  'route10_temp_celsius{stat=\"max\"} '   || json_extract(json,'\$.temp.>')
FROM minutes ORDER BY ts DESC LIMIT 1;
SELECT
  'route10_switch_port_tx_bytes{port=\"' || je.key || '\"} ' || json_extract(je.value,'\$.tx') || char(10) ||
  'route10_switch_port_rx_bytes{port=\"' || je.key || '\"} ' || json_extract(je.value,'\$.rx')
FROM minutes m, json_each(m.json,'\$.ports') je
WHERE m.ts = (SELECT max(ts) FROM minutes)
  AND json_extract(je.value,'\$.tx') IS NOT NULL;
"

# ── obs-collect: newest per-minute sample ───────────────────────────────────
q "file:/a/obs/rt.sql?mode=ro" "
SELECT
  'route10_rt_sample_timestamp_seconds ' || ts || char(10) ||
  'route10_eth_carrier{iface=\"eth4\"} ' || COALESCE(json_extract(json,'\$.carrier.eth4'),'NaN') || char(10) ||
  'route10_eth_carrier{iface=\"eth5\"} ' || COALESCE(json_extract(json,'\$.carrier.eth5'),'NaN') || char(10) ||
  'route10_brlan_addr_present{family=\"ipv4\"} '     || COALESCE(json_extract(json,'\$.addr.v4'),'NaN')  || char(10) ||
  'route10_brlan_addr_present{family=\"ipv6_gua\"} ' || COALESCE(json_extract(json,'\$.addr.gua'),'NaN') || char(10) ||
  'route10_brlan_addr_present{family=\"ipv6_ula\"} ' || COALESCE(json_extract(json,'\$.addr.ula'),'NaN') || char(10) ||
  'route10_wan3_up ' || COALESCE(json_extract(json,'\$.addr.wan3'),'NaN') || char(10) ||
  'route10_conntrack_entries ' || COALESCE(json_extract(json,'\$.ct.n'),'NaN')   || char(10) ||
  'route10_conntrack_limit '   || COALESCE(json_extract(json,'\$.ct.max'),'NaN') || char(10) ||
  'route10_softnet_dropped_total '     || COALESCE(json_extract(json,'\$.softnet.drop'),'NaN')    || char(10) ||
  'route10_softnet_timesqueeze_total ' || COALESCE(json_extract(json,'\$.softnet.squeeze'),'NaN') || char(10) ||
  'route10_optical_power_dbm{module=\"L4\",dir=\"tx\"} ' || COALESCE(json_extract(json,'\$.ddm.l4_tx'),'NaN') || char(10) ||
  'route10_optical_power_dbm{module=\"L4\",dir=\"rx\"} ' || COALESCE(json_extract(json,'\$.ddm.l4_rx'),'NaN') || char(10) ||
  'route10_optical_power_dbm{module=\"W2\",dir=\"tx\"} ' || COALESCE(json_extract(json,'\$.ddm.w2_tx'),'NaN') || char(10) ||
  'route10_optical_power_dbm{module=\"W2\",dir=\"rx\"} ' || COALESCE(json_extract(json,'\$.ddm.w2_rx'),'NaN') || char(10) ||
  'route10_optical_temp_celsius{module=\"L4\"} ' || COALESCE(json_extract(json,'\$.ddm.l4_t'),'NaN') || char(10) ||
  'route10_optical_temp_celsius{module=\"W2\"} ' || COALESCE(json_extract(json,'\$.ddm.w2_t'),'NaN')
FROM samples ORDER BY ts DESC LIMIT 1;
"

# Monotonic /proc/net/dev counters for the CPU-side interfaces (ops #104 ask).
# NOT available for LAN switch ports: ASIC-forwarded frames bypass those
# netdevs (measured — Alta ports 1/4 carry traffic while eth0/eth3 count 0),
# so the rcstats per-minute deltas above remain the only source for ports.
q "file:/a/obs/rt.sql?mode=ro" "
SELECT
  'route10_interface_receive_bytes_total{iface=\"'  || je.key || '\"} ' || json_extract(je.value,'\$.rxb') || char(10) ||
  'route10_interface_transmit_bytes_total{iface=\"' || je.key || '\"} ' || json_extract(je.value,'\$.txb') || char(10) ||
  'route10_interface_receive_packets_total{iface=\"'  || je.key || '\"} ' || json_extract(je.value,'\$.rxp') || char(10) ||
  'route10_interface_transmit_packets_total{iface=\"' || je.key || '\"} ' || json_extract(je.value,'\$.txp')
FROM samples s, json_each(s.json,'\$.if') je
WHERE s.ts = (SELECT max(ts) FROM samples);
"

# ── PON layer (pon-collect.sh, every 15 min) ────────────────────────────────
# Own staleness guard (900s cadence): route10_pon_sample_timestamp_seconds.
# NaN for any field the parser couldn't read this cycle, so a partial diag read
# never silently reports 0 counters.
q "file:/a/obs/rt.sql?mode=ro" "
SELECT
  'route10_pon_sample_timestamp_seconds ' || ts || char(10) ||
  'route10_pon_uptime_seconds '  || COALESCE(json_extract(json,'\$.uptime'),'NaN')     || char(10) ||
  'route10_pon_onu_state '       || COALESCE(json_extract(json,'\$.onu_state'),'NaN')  || char(10) ||
  'route10_pon_alarm{type=\"los\"} '         || COALESCE(json_extract(json,'\$.alarm.los'),'NaN')         || char(10) ||
  'route10_pon_alarm{type=\"lof\"} '         || COALESCE(json_extract(json,'\$.alarm.lof'),'NaN')         || char(10) ||
  'route10_pon_alarm{type=\"lom\"} '         || COALESCE(json_extract(json,'\$.alarm.lom'),'NaN')         || char(10) ||
  'route10_pon_alarm{type=\"sf\"} '          || COALESCE(json_extract(json,'\$.alarm.sf'),'NaN')          || char(10) ||
  'route10_pon_alarm{type=\"sd\"} '          || COALESCE(json_extract(json,'\$.alarm.sd'),'NaN')          || char(10) ||
  'route10_pon_alarm{type=\"tx_too_long\"} ' || COALESCE(json_extract(json,'\$.alarm.tx_too_long'),'NaN') || char(10) ||
  'route10_pon_alarm{type=\"tx_mismatch\"} ' || COALESCE(json_extract(json,'\$.alarm.tx_mismatch'),'NaN') || char(10) ||
  'route10_pon_ds_bip_error_bits_total '        || COALESCE(json_extract(json,'\$.ds.bip_bits'),'NaN')    || char(10) ||
  'route10_pon_ds_bip_error_blocks_total '      || COALESCE(json_extract(json,'\$.ds.bip_blocks'),'NaN')  || char(10) ||
  'route10_pon_ds_fec_corrected_codewords_total '   || COALESCE(json_extract(json,'\$.ds.fec_cor_cw'),'NaN')   || char(10) ||
  'route10_pon_ds_fec_uncorrectable_codewords_total ' || COALESCE(json_extract(json,'\$.ds.fec_uncor_cw'),'NaN') || char(10) ||
  'route10_pon_ds_superframe_los_total ' || COALESCE(json_extract(json,'\$.ds.sf_los'),'NaN')    || char(10) ||
  'route10_pon_ds_ploam_received_total ' || COALESCE(json_extract(json,'\$.ds.ploam_rx'),'NaN')  || char(10) ||
  'route10_pon_ds_ploam_crc_error_total ' || COALESCE(json_extract(json,'\$.ds.ploam_crc'),'NaN') || char(10) ||
  'route10_pon_rogue_sd_too_long_total ' || COALESCE(json_extract(json,'\$.rogue.sd_too_long'),'NaN') || char(10) ||
  'route10_pon_rogue_sd_mismatch_total ' || COALESCE(json_extract(json,'\$.rogue.sd_mismatch'),'NaN')
FROM pon ORDER BY ts DESC LIMIT 1;
"

# ── live, but read-only-cheap ───────────────────────────────────────────────
echo "route10_pstore_files $(ls /sys/fs/pstore 2>/dev/null | wc -l)"
