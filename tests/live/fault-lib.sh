# shellcheck shell=bash
# Shared network-loss steps (Sub-plan 5, Tasks 2.1 and 2.2): live/fault-network
# runs one loss per target; live/soak runs two inside its 24 hours. Sourced
# after tests/live/controller-lib.sh (cs_t; the group defines cs_dir). Defines
# no cases.

NDF_LOSS_S="${NDF_LOSS_S:-120}"
NDF_RETURN_S="${NDF_RETURN_S:-420}"
# bridge-eval's bootstrap resolvers (../tor-socat/bridge-eval/pool.go), the
# declared exception (release/bootstrap.tsv "bridges").
NDF_BOOT_RESOLVERS="1.1.1.1 9.9.9.9 8.8.8.8"
# The fault's own canary (target.sh fault-network): never a bootstrap resolver.
NDF_CANARY=149.112.112.112

# ndf_fresh <alias> <file>: route-report into <file>; prints the rcode of its
# fresh name through Pi-hole.
ndf_fresh() {
  cs_t "$1" route-report >"$2" 2>>"$(cs_dir "$1")/ops.log" || true
  awk -F '\t' '$1 == "section" { on = ($2 == "route"); next } on && $1 == "client_fresh" { print $2; exit }' "$2"
}

ndf_answered() { case "$1" in NOERROR|NXDOMAIN) return 0 ;; esac; return 1; }

# ndf_loss <alias> <dir>: one network loss of NDF_LOSS_S seconds on the
# target, judged: the fault takes hold, fresh names fail throughout, only the
# canary and declared bootstrap lookups were tried, and a fresh name resolves
# within NDF_RETURN_S after the return without any repair here. Writes its
# files into <dir>; prints the seconds from the return to the first answer.
# A trap lifts the fault if this ends early.
ndf_loss() {
  local a="$1" d="$2" r t0 i bad back=""
  mkdir -p "$d"
  trap 'cs_t "'"$a"'" heal-network >>"'"$d"'/heal-trap.tsv" 2>>"$(cs_dir "'"$a"'")/ops.log"' EXIT
  NICE_DNS_FREEZE_MAX_SECS=600 cs_t "$a" fault-network >"$d/fault.tsv" 2>>"$(cs_dir "$a")/ops.log" \
    || fail "$a: fault-network: $(tail -n 3 "$(cs_dir "$a")/ops.log")"
  assert_match '^fault	in-place$' "$(grep '^fault	' "$d/fault.tsv")" "$a: the fault is in place"
  t0="$(date +%s)"; i=0
  while [ $(( $(date +%s) - t0 )) -lt "$NDF_LOSS_S" ]; do
    sleep 25; i=$((i + 1))
    r="$(ndf_fresh "$a" "$d/loss-$i.tsv")"
    ! ndf_answered "$r" || fail "$a: a fresh name resolved $(( $(date +%s) - t0 )) s into the loss: something reached a resolver around the fault"
  done
  cs_t "$a" heal-network >"$d/heal.tsv" 2>>"$(cs_dir "$a")/ops.log" || fail "$a: heal-network"
  trap - EXIT
  assert_match '^fault	lifted$' "$(grep '^fault	' "$d/heal.tsv")" "$a: the fault is lifted"
  # The positive control: the canary the fault sent at its start was dropped
  # and recorded, so an empty list below means no attempt, not a blind spot.
  assert_eq 1 "$(awk -F '\t' -v c="$NDF_CANARY" '$1 == "dns_attempt" && $2 == c && $3 == 53' "$d/heal.tsv" | grep -c .)" \
    "$a: the fault recorded its own canary query"
  bad="$(awk -F '\t' -v boot="$NDF_BOOT_RESOLVERS" -v c="$NDF_CANARY" 'BEGIN { n = split(boot, b, " "); for (i = 1; i <= n; i++) ok[b[i]] = 1; ok[c] = 1 }
    $1 == "dns_attempt" && !($2 in ok && $3 == 53)' "$d/heal.tsv")"
  assert_eq "" "$bad" "$a: during the loss no DNS was tried but the declared bootstrap lookups"
  t0="$(date +%s)"; i=0
  while [ $(( $(date +%s) - t0 )) -lt "$NDF_RETURN_S" ]; do
    i=$((i + 1))
    r="$(ndf_fresh "$a" "$d/return-$i.tsv")"
    if ndf_answered "$r"; then back="$(( $(date +%s) - t0 ))"; break; fi
    sleep 15
  done
  [ -n "$back" ] || fail "$a: no fresh name resolved within $NDF_RETURN_S s after the network returned"
  printf '%s\n' "$back"
}
