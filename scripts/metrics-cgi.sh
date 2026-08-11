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
#
# NOTE: no `--` comments inside these SQL strings. The statement reaches sqlite3
# as a single logical line, so a `--` comments out EVERYTHING after it — which
# silently drops the whole remaining block (cpu, carrier, addr, conntrack,
# softnet, optical) while still exiting 0 and serving a valid-looking page.
# Keep commentary out here at shell level. Use /* */ if it must live inline.
#
# conntrack_entries/_limit are GLOBAL: both families, every scope, including
# LAN<->LAN flows that never reach the ISP NAT, and _limit is our local 500k
# table rather than the ISP session budget — so entries/limit reads ~2% while
# CGNAT saturates. They stay for continuity; alert on wan4 instead, which counts
# only ipv4 flows with a public destination. (Agreed with ops 2026-08-09.)
q "file:/a/obs/rt.sql?mode=ro" "
SELECT
  'route10_rt_sample_timestamp_seconds ' || ts || char(10) ||
  'route10_eth_carrier{iface=\"eth4\"} ' || COALESCE(json_extract(json,'\$.carrier.eth4'),'NaN') || char(10) ||
  'route10_eth_carrier{iface=\"eth5\"} ' || COALESCE(json_extract(json,'\$.carrier.eth5'),'NaN') || char(10) ||
  '# HELP route10_eth_carrier_changes_total Link flap counter. route10_eth_carrier is a 0/1 gauge sampled once a minute and CANNOT see a flap - the 2026-06 eth5 incident was 261 flaps in 3.4 days and a per-minute carrier=1 would have read healthy throughout. Alert on rate() of this, not on the carrier gauge. Resets to 0 on reboot.' || char(10) ||
  'route10_eth_carrier_changes_total{iface=\"eth4\"} '   || COALESCE(json_extract(json,'\$.flap.eth4'),'NaN')  || char(10) ||
  'route10_eth_carrier_changes_total{iface=\"eth5\"} '   || COALESCE(json_extract(json,'\$.flap.eth5'),'NaN')  || char(10) ||
  'route10_eth_carrier_changes_total{iface=\"br-lan\"} ' || COALESCE(json_extract(json,'\$.flap.brlan'),'NaN') || char(10) ||
  '# HELP route10_eth_rx_crc_errors_total Office-fibre receive CRC errors (ethtool driver counter, NOT the /proc/net/dev errs column, which reads 0 while this climbs). This is the counter that hit 51k+ in the 2026-06 dirty-ferrule incident and took the whole LAN down while the WAN was fine. ONE DIRECTION ONLY: route10->office corruption lands on the office switch counters, which we cannot see, so a flat value here does NOT clear the fibre.' || char(10) ||
  'route10_eth_rx_crc_errors_total{iface=\"eth5\"} ' || COALESCE(json_extract(json,'\$.crc.eth5'),'NaN') || char(10) ||
  'route10_brlan_addr_present{family=\"ipv4\"} '     || COALESCE(json_extract(json,'\$.addr.v4'),'NaN')  || char(10) ||
  'route10_brlan_addr_present{family=\"ipv6_gua\"} ' || COALESCE(json_extract(json,'\$.addr.gua'),'NaN') || char(10) ||
  'route10_brlan_addr_present{family=\"ipv6_ula\"} ' || COALESCE(json_extract(json,'\$.addr.ula'),'NaN') || char(10) ||
  'route10_wan3_up ' || COALESCE(json_extract(json,'\$.addr.wan3'),'NaN') || char(10) ||
  '# HELP route10_conntrack_entries NOT a NAT metric. Kernel table, BOTH families, EVERY scope, including LAN-to-LAN flows that never reach the ISP. For CGNAT pressure use route10_conntrack_wan4.' || char(10) ||
  '# HELP route10_conntrack_limit NOT the ISP session budget. Our local nf_conntrack_max (500k). The entries/limit ratio renders ~0.4 percent green while CGNAT saturates; it has misled both sides. Use route10_conntrack_wan4 against ~1400.' || char(10) ||
  'route10_conntrack_entries ' || COALESCE(json_extract(json,'\$.ct.n'),'NaN')   || char(10) ||
  'route10_conntrack_limit '   || COALESCE(json_extract(json,'\$.ct.max'),'NaN') || char(10) ||
  'route10_conntrack_v4 '   || COALESCE(json_extract(json,'\$.ct.v4'),'NaN')   || char(10) ||
  'route10_conntrack_v6 '   || COALESCE(json_extract(json,'\$.ct.v6'),'NaN')   || char(10) ||
  'route10_conntrack_wan4 ' || COALESCE(json_extract(json,'\$.ct.wan4'),'NaN') || char(10) ||
  'route10_softnet_dropped_total '     || COALESCE(json_extract(json,'\$.softnet.drop'),'NaN')    || char(10) ||
  'route10_host_flows_topn 10' || char(10) ||
  'route10_softnet_timesqueeze_total ' || COALESCE(json_extract(json,'\$.softnet.squeeze'),'NaN') || char(10) ||
  'route10_optical_power_dbm{module=\"L4\",dir=\"tx\"} ' || COALESCE(json_extract(json,'\$.ddm.l4_tx'),'NaN') || char(10) ||
  'route10_optical_power_dbm{module=\"L4\",dir=\"rx\"} ' || COALESCE(json_extract(json,'\$.ddm.l4_rx'),'NaN') || char(10) ||
  'route10_optical_power_dbm{module=\"W2\",dir=\"tx\"} ' || COALESCE(json_extract(json,'\$.ddm.w2_tx'),'NaN') || char(10) ||
  'route10_optical_power_dbm{module=\"W2\",dir=\"rx\"} ' || COALESCE(json_extract(json,'\$.ddm.w2_rx'),'NaN') || char(10) ||
  'route10_optical_temp_celsius{module=\"L4\"} ' || COALESCE(json_extract(json,'\$.ddm.l4_t'),'NaN') || char(10) ||
  'route10_optical_temp_celsius{module=\"W2\"} ' || COALESCE(json_extract(json,'\$.ddm.w2_t'),'NaN') || char(10) ||
  '# HELP route10_optical_bias_ma Laser bias current. The LEADING ageing indicator: bias climbing while route10_optical_power_dbm{dir=tx} stays flat means the laser is being driven harder to hold its output, which is how a DFB dies - visible weeks before Tx power sags. Trend it per module, do not threshold it absolutely.' || char(10) ||
  'route10_optical_voltage_volts{module=\"L4\"} ' || COALESCE(json_extract(json,'\$.ddm.l4_v'),'NaN') || char(10) ||
  'route10_optical_voltage_volts{module=\"W2\"} ' || COALESCE(json_extract(json,'\$.ddm.w2_v'),'NaN') || char(10) ||
  'route10_optical_bias_ma{module=\"L4\"} ' || COALESCE(json_extract(json,'\$.ddm.l4_a'),'NaN') || char(10) ||
  'route10_optical_bias_ma{module=\"W2\"} ' || COALESCE(json_extract(json,'\$.ddm.w2_a'),'NaN') || char(10) ||
  '# HELP route10_dns_up A LADDER, not one verdict: each resolver hop probed independently so the broken hop names itself. resolver=\"adguard\" 0 with the rest 1 means an ops-side outage AND that ad-blocking is silently OFF (we are serving from the DoH fallback). resolver=\"dnsmasq\" 1 does NOT prove LAN DNS is healthy - it answers the stable probe name from cache while the whole upstream chain is dead.' || char(10) ||
  'route10_dns_up{resolver=\"adguard\"} '  || COALESCE(json_extract(json,'\$.dns.agh_up'),'NaN')     || char(10) ||
  'route10_dns_up{resolver=\"doh\"} '      || COALESCE(json_extract(json,'\$.dns.doh_up'),'NaN')     || char(10) ||
  'route10_dns_up{resolver=\"routedns\"} ' || COALESCE(json_extract(json,'\$.dns.rdns_up'),'NaN')    || char(10) ||
  'route10_dns_up{resolver=\"dnsmasq\"} '  || COALESCE(json_extract(json,'\$.dns.dnsmasq_up'),'NaN') || char(10) ||
  '# HELP route10_dns_query_ms Probe latency per hop. On failure this reads the 2000 ms probe CEILING, not a real measurement - gate on route10_dns_up before trusting it. Stable probe name, so this is liveness latency and NOT cold-lookup latency.' || char(10) ||
  'route10_dns_query_ms{resolver=\"adguard\"} '  || COALESCE(json_extract(json,'\$.dns.agh_ms'),'NaN')     || char(10) ||
  'route10_dns_query_ms{resolver=\"doh\"} '      || COALESCE(json_extract(json,'\$.dns.doh_ms'),'NaN')     || char(10) ||
  'route10_dns_query_ms{resolver=\"routedns\"} ' || COALESCE(json_extract(json,'\$.dns.rdns_ms'),'NaN')    || char(10) ||
  'route10_dns_query_ms{resolver=\"dnsmasq\"} '  || COALESCE(json_extract(json,'\$.dns.dnsmasq_ms'),'NaN')
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
  'route10_interface_transmit_packets_total{iface=\"' || je.key || '\"} ' || json_extract(je.value,'\$.txp') || char(10) ||
  'route10_interface_receive_errors_total{iface=\"'  || je.key || '\"} ' || COALESCE(json_extract(je.value,'\$.rxe'),'NaN') || char(10) ||
  'route10_interface_receive_dropped_total{iface=\"' || je.key || '\"} ' || COALESCE(json_extract(je.value,'\$.rxd'),'NaN') || char(10) ||
  'route10_interface_receive_fifo_total{iface=\"'    || je.key || '\"} ' || COALESCE(json_extract(je.value,'\$.rxf'),'NaN')
FROM samples s, json_each(s.json,'\$.if') je
WHERE s.ts = (SELECT max(ts) FROM samples);
"

# ── per-host offenders (top 10 per family, from the same sample) ─────────────
#
# What a connlimit alert cannot say on its own: WHICH device. The log line names
# a source address; this names the host and shows the field, so "over the cap" can
# be read next to who else was competing for the same budget.
#
# Cardinality is bounded by top-N (<=20 series), but v6 label VALUES churn as
# SLAAC privacy addresses rotate, so the series count grows slowly over time.
# That is the accepted cost of naming the actual offending address; the host
# label stays stable across a rotation, so query on `host`, not on `ip`.
#
# Names are verbatim from DHCP, uncurated by explicit operator decision — it is a
# private LAN and a masked offender list is worth less than an honest one.
q "file:/a/obs/rt.sql?mode=ro" "
SELECT group_concat(line, char(10)) FROM (
  SELECT 'route10_host_flows{family=\"' || fam ||
         '\",host=\"' || json_extract(e.value,'\$.h') ||
         '\",ip=\"'   || json_extract(e.value,'\$.ip') || '\"} ' ||
         json_extract(e.value,'\$.n') AS line
  FROM (SELECT json, 'v4' AS fam, '\$.ct.top4' AS path FROM samples WHERE ts=(SELECT max(ts) FROM samples)
        UNION ALL
        SELECT json, 'v6' AS fam, '\$.ct.top6' AS path FROM samples WHERE ts=(SELECT max(ts) FROM samples)) s,
       json_each(json_extract(s.json, s.path)) e
);
"

# ── PASSIVE experience signal: TCP connections that never established ───────
#
# The one metric here that measures the USER's traffic rather than our own. An
# ICMP probe cannot characterise a phone (measured: an iPhone answered every echo
# in all 11 minutes it was passing traffic and lost all five in all 5 minutes it
# was idle — the probe reports iOS power management, not the link). This has the
# inverse property: a sleeping device opens no connections, so idleness yields NO
# signal rather than a false one. And SYN_SENT is literally the reported symptom —
# a connection attempted that never completed, which is what "the last few images
# of the post do not load" IS.
#
# ⚠ BOTH numbers are exported on purpose. The ratio is the interesting value and
# is meaningless alone: 1 unanswered of 1 flow is 100% and says nothing. Gate on
# the denominator before displaying a ratio:
#   route10_host_tcp_unanswered / route10_host_tcp_flows   and   flows >= 10
#
# ⚠ CONDITIONAL EMITTER — absence means "nothing to report", NEVER "removed".
# The series come from json_each() over $.ct.stall4, which obs-collect fills
# with the top-N LAN hosts holding OUTBOUND TCP conntrack entries to PUBLIC
# destinations. No such flows ⇒ empty array ⇒ json_each yields no rows ⇒ the
# names vanish from /metrics entirely. That is normal, and it is guaranteed
# during a WAN outage: no internet means nothing dials out, so the metric
# that measures failed outbound connections has nothing to measure.
# Consumers diffing the name set must treat these as may-be-absent (asked by
# ops 2026-08-11, after they saw them disappear at outage onset and correctly
# asked rather than filing it as a regression).
#
# ⚠ p2p makes SYN_SENT normal. A torrent host dials peers that are simply gone,
# so it sits high on a perfectly healthy day. Read a host against ITS OWN trailing
# baseline, never against an absolute threshold or against other hosts.
#
# ⚠ It is a ~2-minute smear, not an instant: nf_conntrack_tcp_timeout_syn_sent is
# 120 s (verified on the box), so a failed SYN lingers twice the 60 s sampling
# period. That means a fast burst CANNOT be missed — but it also means the metric
# says a burst failed within a window, never which burst.
q "file:/a/obs/rt.sql?mode=ro" "
SELECT group_concat(line, char(10)) FROM (
  SELECT 'route10_host_tcp_flows{family=\"v4\",host=\"' || json_extract(e.value,'\$.h') ||
         '\",ip=\"' || json_extract(e.value,'\$.ip') || '\"} ' ||
         json_extract(e.value,'\$.tcp') || char(10) ||
         'route10_host_tcp_unanswered{family=\"v4\",host=\"' || json_extract(e.value,'\$.h') ||
         '\",ip=\"' || json_extract(e.value,'\$.ip') || '\"} ' ||
         json_extract(e.value,'\$.syn') AS line
  FROM samples s, json_each(json_extract(s.json, '\$.ct.stall4')) e
  WHERE s.ts = (SELECT max(ts) FROM samples)
);
"

# ── LAN quality probe (lan-probe.sh, every 1 min) ───────────────────────────
#
# `present` is the CONTROL and must be read alongside loss, not after it: a phone
# that is asleep, off, or on cellular reports present=0 and its loss/rtt are null.
# Alerting on loss without gating on present=1 manufactures a nightly outage every
# time the device is put down — which is how a real signal gets ignored.
#
# `medium` is the second control. wifi degrading while wired/ap stay clean isolates
# the air link; everything degrading together points at route10 or the LAN.
#
# rtt_min is the third control, and the one a dashboard is most likely to skip.
# 802.11 power-save parks a phone between beacons, so avg/max climb into the
# hundreds of ms on a HEALTHY link. Plot rtt_ms alone and the panel is red forever
# for a device that is merely saving battery. Read min and max together:
#   min flat + max high => the device slept; the air is fine
#   min risen           => the floor moved; congestion or a genuinely bad link
#
# ⛔ But do NOT plot raw rtt_min. Each run sends only 5 echoes, so if a sleepy
# device is parked for all five, that run's "floor" is a wakeup latency and not a
# path latency. Per-burst min is therefore noisy for exactly the devices this
# control exists for; the estimate improves with the number of BURSTS, not with
# anything inside one. Measured: one target's per-burst floor ranged 2.8-50.5 ms
# over 16 samples while its true floor sat at the bottom of that range.
# Use a rolling low quantile as link health:
#   quantile_over_time(0.05, route10_lan_probe_rtt_min_ms[15m])   (or min_over_time)
# and keep raw rtt_max as the felt tail. The GAP between them is the variance,
# which is often the only thing the data actually establishes.
# `dup` corroborates independently — duplicate echo replies mean 802.11 had to
# retransmit, which power-save cannot produce. It is the only field here a
# sleeping device cannot fake.
#
# Absent devices emit NaN, NOT a missing series: the series is always present so
# `absent()` never fires on a sleeping phone, but any aggregation that touches a
# NaN returns NaN. Gate on present=1 rather than relying on the value.
#
# Staleness: lanq is its OWN table on its OWN cron, so route10_rt_sample_timestamp
# does not cover it — obs-collect can be perfectly healthy while lan-probe is dead,
# and the query below serves the last row forever with nothing to say it is old.
# Every other feed here declares its own age; this one must too.
q "file:/a/obs/rt.sql?mode=ro" "
SELECT 'route10_lan_probe_sample_timestamp_seconds ' || COALESCE(max(ts),'NaN') FROM lanq;
"
q "file:/a/obs/rt.sql?mode=ro" "
SELECT group_concat(line, char(10)) FROM (
  SELECT 'route10_lan_probe_present{host=\"' || json_extract(e.value,'\$.n') ||
         '\",ip=\"' || json_extract(e.value,'\$.ip') ||
         '\",medium=\"' || json_extract(e.value,'\$.m') || '\"} ' || json_extract(e.value,'\$.present') || char(10) ||
         'route10_lan_probe_rtt_ms{host=\"' || json_extract(e.value,'\$.n') ||
         '\",ip=\"' || json_extract(e.value,'\$.ip') ||
         '\",medium=\"' || json_extract(e.value,'\$.m') || '\"} ' || COALESCE(json_extract(e.value,'\$.rtt'),'NaN') || char(10) ||
         'route10_lan_probe_rtt_min_ms{host=\"' || json_extract(e.value,'\$.n') ||
         '\",ip=\"' || json_extract(e.value,'\$.ip') ||
         '\",medium=\"' || json_extract(e.value,'\$.m') || '\"} ' || COALESCE(json_extract(e.value,'\$.rttmin'),'NaN') || char(10) ||
         'route10_lan_probe_rtt_max_ms{host=\"' || json_extract(e.value,'\$.n') ||
         '\",ip=\"' || json_extract(e.value,'\$.ip') ||
         '\",medium=\"' || json_extract(e.value,'\$.m') || '\"} ' || COALESCE(json_extract(e.value,'\$.rttmax'),'NaN') || char(10) ||
         'route10_lan_probe_duplicates{host=\"' || json_extract(e.value,'\$.n') ||
         '\",ip=\"' || json_extract(e.value,'\$.ip') ||
         '\",medium=\"' || json_extract(e.value,'\$.m') || '\"} ' || COALESCE(json_extract(e.value,'\$.dup'),'NaN') || char(10) ||
         'route10_lan_probe_lease_seconds_remaining{host=\"' || json_extract(e.value,'\$.n') ||
         '\",ip=\"' || json_extract(e.value,'\$.ip') ||
         '\",medium=\"' || json_extract(e.value,'\$.m') || '\"} ' || COALESCE(json_extract(e.value,'\$.lease'),'NaN') || char(10) ||
         'route10_lan_probe_loss_percent{host=\"' || json_extract(e.value,'\$.n') ||
         '\",ip=\"' || json_extract(e.value,'\$.ip') ||
         '\",medium=\"' || json_extract(e.value,'\$.m') || '\"} ' || COALESCE(json_extract(e.value,'\$.loss'),'NaN') AS line
  FROM lanq l, json_each(l.json) e
  WHERE l.ts = (SELECT max(ts) FROM lanq)
);
"

# ── PON layer (pon-collect.sh, every 1 min) ─────────────────────────────────
# Own staleness guard (60s cadence): route10_pon_sample_timestamp_seconds.
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
  'route10_pon_rogue_sd_mismatch_total ' || COALESCE(json_extract(json,'\$.rogue.sd_mismatch'),'NaN') || char(10) ||
  'route10_pon_ranging_requests_total ' || COALESCE(json_extract(json,'\$.act.ranging_req'),'NaN') || char(10) ||
  'route10_pon_sn_requests_total '      || COALESCE(json_extract(json,'\$.act.sn_req'),'NaN')      || char(10) ||
  'route10_pon_us_sn_ploam_sent_total ' || COALESCE(json_extract(json,'\$.us.tx_sn_ploam'),'NaN')  || char(10) ||
  'route10_pon_us_burst_overhead_total ' || COALESCE(json_extract(json,'\$.us.tx_boh'),'NaN')      || char(10) ||
  'route10_pon_omci_processed_total ' || COALESCE(json_extract(json,'\$.omci.processed'),'NaN')    || char(10) ||
  'route10_pon_omci_dropped_total '   || COALESCE(json_extract(json,'\$.omci.dropped'),'NaN')      || char(10) ||
  'route10_pon_ds_bwmap_crc_error_total ' || COALESCE(json_extract(json,'\$.bw.crc_err'),'NaN')    || char(10) ||
  'route10_pon_ds_bwmap_invalid_total{slot=\"0\"} ' || COALESCE(json_extract(json,'\$.bw.invalid0'),'NaN') || char(10) ||
  'route10_pon_ds_bwmap_invalid_total{slot=\"1\"} ' || COALESCE(json_extract(json,'\$.bw.invalid1'),'NaN') || char(10) ||
  'route10_pon_omci_requests_total '    || COALESCE(json_extract(json,'\$.omci_tx.req'),'NaN')  || char(10) ||
  'route10_pon_omci_retransmits_total ' || COALESCE(json_extract(json,'\$.omci_tx.retx'),'NaN')
FROM pon ORDER BY ts DESC LIMIT 1;
"

# ── live, but read-only-cheap ───────────────────────────────────────────────
echo "route10_pstore_files $(ls /sys/fs/pstore 2>/dev/null | wc -l)"
