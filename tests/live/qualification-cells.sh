# shellcheck shell=bash
# Group live/qualification-cells (sub-plan 05 Task 2.3, Stage 2 gate; ARCH-09).
# A row of plan qualification. Run with
#   tests/run.sh live qualification-cells --live --targets FILE --platforms all
#
# Every cell of the eight-cell matrix on its platform's target, the hosts at
# once and each host's four cells in turn (user decisions 2026-10-06: the
# 24 h soak and the latency stand for their platform through the linked soak
# receipt; each cell gets these checks):
#   install    the cell (install-cell, standard or hardened Pi-hole), then
#              the frozen candidate proxy built from the sibling's HEAD on the
#              target and recreated (as live/soak does: the candidates are not
#              released);
#   QU-COLD-START   from the candidate proxy's start, a fresh name resolves
#              within NDF_RETURN_S (420 s), with no manual repair;
#   QU-NO-DIRECT    live/no-direct's capture (ndx_capture) on this cell;
#   QU-NETWORK-LOSS live/fault-network's loss (ndf_cell) on this cell.
# Each host ends on its representative cell (linux haproxy/standard, macos
# socat/standard: the soak's), on the frozen candidate. A failed check ends
# that host's run (the cells after it are not observed, and the receipt
# then cannot verify).
# Evidence: $ARTIFACT_DIR/qualification-cells/<alias>/<platform-proxy-pihole>/
# (cell.tsv, install log, identity.tsv, no-direct/, network-loss/).

# shellcheck source=tests/live/install-lifecycle.sh
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private
# shellcheck source=tests/live/no-direct.sh
. "$NICE_DNS_ROOT/tests/live/no-direct.sh"
unset -f t_1_capture t_2_evidence_is_private
# shellcheck source=tests/live/fault-network.sh
. "$NICE_DNS_ROOT/tests/live/fault-network.sh"
unset -f t_1_network_loss t_2_evidence_is_private

IL_FIRST_STEPS=qc_host
QC_KEY=""     # the cell being checked: <platform>-<proxy>-<pihole>
QC_PHASE=""   # its check: no-direct | network-loss
il_dir() { printf '%s\n' "$ARTIFACT_DIR/qualification-cells/$1${QC_KEY:+/$QC_KEY}"; }
cs_dir() { printf '%s\n' "$(il_dir "$1")${QC_PHASE:+/$QC_PHASE}"; }

# qc_cells <platform>: its four cells, the soak's representative cell last.
# NICE_DNS_QC_CELLS (proxy/pihole,...) keeps only those, for a dry run; the
# gate runs all of them (the receipt then holds every cell or fails).
qc_cells() {
  local c
  for c in $(if [ "$1" = linux ]; then echo socat/standard socat/hardened haproxy/hardened haproxy/standard
             else echo haproxy/standard haproxy/hardened socat/hardened socat/standard; fi); do
    case ",${NICE_DNS_QC_CELLS:-$c}," in *",$c,"*) printf '%s\n' "$c" ;; esac
  done
}

qc_sha() {
  local r="$NICE_DNS_ROOT/../$1"
  [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$r" status --porcelain --untracked-files=no)" ] || fail "$1 is not committed (the archive is of its HEAD)"
  git -C "$r" rev-parse HEAD
}

# qc_cell <platform> <alias> <proxy/pihole>: one cell, all its checks.
qc_cell() {
  local plat="$1" a="$2" proxy="${3%/*}" ph="${3#*/}" d psha gen t0 k r
  QC_KEY="$plat-$proxy-$ph" QC_PHASE=""
  d="$(il_dir "$a")"; mkdir -p "$d"
  {
    printf 'cell\t%s/%s/%s\nproxy\t%s\npihole\t%s\nsource_sha\t%s\n' "$plat" "$proxy" "$ph" "$proxy" "$ph" "$(il_sha)"
    [ "$ph" = standard ] || printf 'hardened_sha\t%s\n' "$(qc_sha pi-hole-hardened)"
  } >"$d/cell.tsv"
  il_t "$a" snapshot >>"$d/ops.log" 2>&1 || fail "$a $QC_KEY: snapshot"
  # Room for the install and the proxy build (macOS: older generations and
  # the builder cache go; the running one and its rollback stay).
  il_t "$a" prune-generations >"$d/prune.tsv" 2>>"$d/ops.log" || fail "$a $QC_KEY: prune-generations: $(tail -n 3 "$d/ops.log")"
  il_install "$a" candidate install "$ph" || fail "$a $QC_KEY: the install failed: $(tail -n 20 "$d/install-candidate.log")"
  il_watch_pinned "$plat" "$d/watch-candidate.tsv" all
  psha="$(qc_sha "tor-$proxy")"
  printf 'proxy_sha\t%s\n' "$psha" >>"$d/cell.tsv"
  il_t "$a" build-proxy --component "tor-$proxy" --source-sha "$psha" >"$d/build-proxy.tsv" 2>>"$d/ops.log" \
    || fail "$a $QC_KEY: build-proxy: $(tail -n 10 "$d/ops.log")"
  il_t "$a" recreate-proxy --component "tor-$proxy" >"$d/recreate-proxy.tsv" 2>>"$d/ops.log" \
    || fail "$a $QC_KEY: recreate-proxy: $(tail -n 10 "$d/ops.log")"
  # QU-COLD-START: the stack, just installed and its proxy just started,
  # answers a fresh name (a fresh name every 15 s, up to NDF_RETURN_S).
  t0="$(date +%s)"; k=0
  while :; do
    k=$((k + 1))
    r="$(ndf_fresh "$a" "$d/cold-start-$k.tsv")"
    ndf_answered "$r" && break
    [ $(( $(date +%s) - t0 )) -lt "$NDF_RETURN_S" ] || fail "$a $QC_KEY: no fresh name within $NDF_RETURN_S s of the candidate start ($r)"
    sleep 15
  done
  printf 'cold_start\tpass\nfirst_answer_s\t%s\nmanual_repair\tnone\n' "$(( $(date +%s) - t0 ))" >"$d/cold-start.tsv"
  il_report "$a" identity || fail "$a $QC_KEY: lifecycle-report"
  gen="$(il_val "$d/identity.tsv" generation current)"
  [ -n "$gen" ] && [ "$gen" != - ] || fail "$a $QC_KEY: no current generation after the install"
  printf 'generation\tgeneration=%s;proxy=%s\n' "$gen" "${psha:0:12}" >>"$d/cell.tsv"
  QC_PHASE=no-direct; ndx_capture "$plat" "$a"
  QC_PHASE=network-loss; ndf_cell "$plat" "$a"
  QC_PHASE=""
  printf 'checked\tcold-start no-direct network-loss\n' >>"$d/cell.tsv"
}

qc_host() {
  local plat="$1" a="$2" c
  [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$NICE_DNS_ROOT" status --porcelain --untracked-files=no)" ] || fail "the checkout is not committed (the archive is of HEAD)"
  for c in $(qc_cells "$plat"); do
    qc_cell "$plat" "$a" "$c"
  done
  QC_KEY=""
  printf 'cell\t%s\n' "$plat/host" >"$(il_dir "$a")/cell.tsv"
}

t_1_cells() {
  cs_selection
  il_each qc_host
}

t_2_evidence_is_private() {
  [ -d "$ARTIFACT_DIR/qualification-cells" ] || fail "no evidence: t_1 did not run"
  assert_eq "" "$(grep -rlE 'obfs4 [0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+|cert=[A-Za-z0-9+/=]{16,}' "$ARTIFACT_DIR/qualification-cells" 2>/dev/null)" \
    "no bridge line in the evidence"
}
