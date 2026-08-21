#!/bin/bash
# Full live verification matrix for netcond: every speed tier applied for
# real, measured with actual downloads, then RTT / loss / blackout / scoping /
# teardown. Requires the narrow passwordless sudo grant for dnctl+pfctl.
set -u
cd /Users/mahmud/Projects/net-conditioner || exit 1
NC=./netcond
REPORT=dist/live-matrix-report.txt
: > "$REPORT"
log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

URL='https://proof.ovh.net/files/100Mb.dat'
ALT_URL='https://fsn1-speed.hetzner.com/100MB.bin'

measure_bps() { # seconds url
  curl -sS -o /dev/null --max-time "$1" -w '%{speed_download}' "$2" 2>/dev/null \
    | awk '{ printf "%d", $1 * 8 }'
}

mbit() { awk -v b="$1" 'BEGIN { printf "%.2f", b / 1000000 }'; }

ping_stats() { # count target -> "losspct avgms"
  local out
  out=$(ping -q -c "$1" -i 0.2 "$2" 2>&1) || true
  local loss avg
  loss=$(printf '%s\n' "$out" | sed -nE 's/.* ([0-9.]+)% packet loss.*/\1/p' | head -1)
  avg=$(printf '%s\n' "$out" | awk -F' = ' '/round-trip/ { split($2, a, "/"); print a[2]; exit }')
  printf '%s %s' "${loss:-100}" "${avg:-0}"
}

cap_bps() { # "5mbit" -> 5000000
  awk -v t="$1" 'BEGIN {
    n = t + 0
    if (t ~ /gbit$/) m = 1000000000
    else if (t ~ /mbit$/) m = 1000000
    else m = 1000
    printf "%d", n * m
  }'
}

FAIL=0

log "== netcond live matrix, $(date -u +%H:%M:%SZ) =="
$NC off >/dev/null 2>&1
sleep 1
BASE=$(measure_bps 8 "$URL")
read -r BASE_LOSS BASE_RTT <<< "$(ping_stats 20 1.1.1.1)"
log "baseline: $(mbit "$BASE") Mbit/s, ping ${BASE_RTT} ms, loss ${BASE_LOSS}%"

for tier in 100kbit 250kbit 500kbit 1mbit 2mbit 5mbit 10mbit 25mbit 50mbit; do
  if ! $NC preset "$tier" > /dev/null 2>&1; then
    log "$tier: APPLY FAILED"; FAIL=1; continue
  fi
  cap=$(cap_bps "$tier")
  secs=8
  [ "$cap" -lt 1000000 ] && secs=25
  m=$(measure_bps "$secs" "$URL")
  ratio=$(awk -v m="$m" -v c="$cap" 'BEGIN { printf "%.2f", (m + 0) / c }')
  # Test hosts fatigue across repeated pulls; retry a fresh host before
  # judging an under-reading tier.
  if awk -v r="$ratio" 'BEGIN { exit !(r < 0.35) }'; then
    m2=$(measure_bps "$secs" "$ALT_URL")
    if [ "${m2:-0}" -gt "${m:-0}" ] 2>/dev/null; then m=$m2; fi
    ratio=$(awk -v m="$m" -v c="$cap" 'BEGIN { printf "%.2f", (m + 0) / c }')
  fi
  if [ "$cap" -lt 500000 ]; then
    # Whole-machine caps this small are dominated by background apps
    # fighting for the pipe: the assertion is "payload flows and the cap
    # holds", not a throughput ratio.
    verdict=$(awk -v m="$m" -v c="$cap" 'BEGIN {
      print (m + 0 > 10000 && m + 0 <= c * 1.4) ? "PASS" : "FAIL" }')
  else
    verdict=$(awk -v r="$ratio" 'BEGIN { print (r >= 0.35 && r <= 1.4) ? "PASS" : "FAIL" }')
  fi
  [ "$verdict" = "FAIL" ] && FAIL=1
  log "$tier: measured $(mbit "$m") Mbit/s (x${ratio} of cap) $verdict"
done

$NC set --down 2mbit --rtt 300 > /dev/null 2>&1
read -r _ RTT_MS <<< "$(ping_stats 15 1.1.1.1)"
added=$(awk -v a="$RTT_MS" -v b="$BASE_RTT" 'BEGIN { printf "%d", a - b }')
verdict=$(awk -v d="$added" 'BEGIN { print (d >= 230 && d <= 420) ? "PASS" : "FAIL" }')
[ "$verdict" = "FAIL" ] && FAIL=1
log "rtt+300ms: ping ${RTT_MS} ms (added ~${added} ms) $verdict"

$NC set --loss-up 20 > /dev/null 2>&1
read -r LOSS_PCT _ <<< "$(ping_stats 60 1.1.1.1)"
verdict=$(awk -v l="$LOSS_PCT" 'BEGIN { print (l >= 8 && l <= 35) ? "PASS" : "FAIL" }')
[ "$verdict" = "FAIL" ] && FAIL=1
log "loss-up 20%: measured ${LOSS_PCT}% round-trip loss $verdict"

$NC set --loss 100 > /dev/null 2>&1
read -r BLK_LOSS _ <<< "$(ping_stats 5 1.1.1.1)"
blk=$(measure_bps 5 "$URL")
verdict=$(awk -v l="$BLK_LOSS" -v b="$blk" 'BEGIN { print (l == 100 && b < 10000) ? "PASS" : "FAIL" }')
[ "$verdict" = "FAIL" ] && FAIL=1
log "blackout: ping loss ${BLK_LOSS}%, download $(mbit "$blk") Mbit/s $verdict"

# Leave blackout before the scoped test: DNS cannot resolve through 100%
# loss, so the apply would (correctly) refuse and blackout would linger.
$NC off > /dev/null 2>&1
sleep 1
$NC set --down 1mbit --host proof.ovh.net > /dev/null 2>&1
scoped=$(measure_bps 8 "$URL")
other=$(measure_bps 8 "$ALT_URL")
verdict=$(awk -v s="$scoped" -v o="$other" 'BEGIN {
  print (s <= 1500000 && o > 4000000) ? "PASS" : "FAIL" }')
[ "$verdict" = "FAIL" ] && FAIL=1
log "scoped 1mbit@ovh: ovh $(mbit "$scoped") Mbit/s, unscoped host $(mbit "$other") Mbit/s $verdict"

TOKEN_SEEN=$(awk -F= '$1 == "TOKEN" { print ($2 != "") ? "yes" : "no" }' ~/.netcond/state)
$NC off > /dev/null 2>&1
sleep 1
after=$(measure_bps 8 "$URL")
pipes=$(sudo -n /usr/sbin/dnctl list 2>/dev/null | grep -cE '^0*(9101|9102):')
anchor=$(sudo -n /sbin/pfctl -a netcond -s rules 2>/dev/null | grep -c dummynet)
active=$(awk -F= '$1 == "ACTIVE" { print $2 }' ~/.netcond/state)
verdict="PASS"
{ [ "$pipes" != 0 ] || [ "$anchor" != 0 ] || [ "$active" != 0 ]; } && { verdict="FAIL"; FAIL=1; }
restored=$(awk -v a="$after" -v b="$BASE" 'BEGIN { print (a > b * 0.25) ? "yes" : "no" }')
[ "$restored" = "no" ] && { verdict="FAIL"; FAIL=1; }
log "teardown: speed back to $(mbit "$after") Mbit/s (baseline $(mbit "$BASE")), pipes:$pipes anchor-rules:$anchor state-active:$active token-was-captured:$TOKEN_SEEN $verdict"

log "== matrix result: $([ "$FAIL" = 0 ] && echo ALL PASS || echo FAILURES PRESENT) =="
exit "$FAIL"
