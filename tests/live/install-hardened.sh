# shellcheck shell=bash
# Group live/install-hardened (Sub-plan 4 Stage 2 gate; ARCH-06, ARCH-09).
# Run by `plan installers` after live/install-lifecycle, or alone with
# `tests/run.sh live install-hardened --live --targets FILE`.
#
# The installers receipt needs every entrypoint to pass on a real target
# (user decision 2026-09-28): each platform's hardened entrypoint runs once,
# over the standard deployment the target runs now, with the proxy it runs:
#
#   install hardened   install-{deb,mac}-hardened.sh from this checkout's HEAD
#                      and the pi-hole-hardened sibling's HEAD; the resolver
#                      never leaves the stack; the deployment is checked as
#                      in live/install-lifecycle, and it is the hardened one
#   uninstall          with the same entrypoint: the recorded DNS state is
#                      back and nothing owned is left
#   install standard   the target ends on the standard stack it started on
#
# Full qualification of the hardened cells stays with Sub-plan 5. Evidence:
# $ARTIFACT_DIR/install-hardened/<alias>/, entrypoint.tsv on success.

# shellcheck source=tests/live/install-lifecycle.sh
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
# Only this group's case: the lifecycle's own cases are that group's.
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private

il_dir() { printf '%s\n' "$ARTIFACT_DIR/install-hardened/$1"; }
IH_SIB="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}/pi-hole-hardened"

# ih_reused <alias> <entrypoint>: the entrypoint.tsv of a run listed in
# NICE_DNS_CELL_REUSE_RUNS that passed this group with <entrypoint> on
# <alias>, at a commit whose product files equal HEAD's and with this
# checkout's pi-hole-hardened HEAD (DEC-009).
ih_reused() {
  local r f
  for r in ${NICE_DNS_CELL_REUSE_RUNS:-}; do
    f="$r/install-hardened/$1/entrypoint.tsv"
    [ -f "$f" ] || continue
    awk -F '\t' '$1 == "live/install-hardened" { n++; if ($4 != "pass") bad = 1 } END { exit !(n >= 1 && !bad) }' "$r/results.tsv" 2>/dev/null || continue
    [ "$(awk -F '\t' '$1 == "entrypoint" && $3 == "pass" { print $2 }' "$f")" = "$2" ] || continue
    [ "$(il_cell_of_dir "$(dirname "$f")" adapter)" = "$( [ -n "${NICE_DNS_TARGET_ADAPTER:-}" ] && echo fake || echo real)" ] || continue
    il_same_product "$(il_cell_of_dir "$(dirname "$f")" source_sha)" "$(il_cell_of_dir "$(dirname "$f")" cell | cut -d/ -f1)" || continue
    [ "$(il_cell_of_dir "$(dirname "$f")" hardened_sha)" = "$(git -C "$IH_SIB" rev-parse HEAD)" ] || continue
    printf '%s\n' "$f"; return 0
  done
  return 0
}
il_cell_of_dir() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1/cell.tsv"; }

il_hardened() {
  local plat="$1" a="$2" d proxy ent r src
  d="$(il_dir "$a")"
  case "$plat" in linux) ent=install-deb-hardened.sh ;; *) ent=install-mac-hardened.sh ;; esac
  src="$(ih_reused "$a" "$ent")"
  if [ -n "$src" ]; then
    printf '%s\t%s\n' "$ent" "$src" >"$d/reused.tsv"
    echo "$ent on $a passed in $src (DEC-009); not repeated"
    return 0
  fi
  if [ "${NICE_DNS_IL_DRY_RUN:-0}" = 1 ]; then
    echo "dry run: the committed-checkout check is skipped"
  else
    assert_eq "" "$(GIT_OPTIONAL_LOCKS=0 git -C "$NICE_DNS_ROOT" status --porcelain --untracked-files=no)" "the checkout is committed (the archive is of HEAD)"
    assert_eq "" "$(GIT_OPTIONAL_LOCKS=0 git -C "$IH_SIB" status --porcelain --untracked-files=no)" "pi-hole-hardened is committed (its archive is of HEAD)"
  fi
  # target.sh changes a target only after a snapshot in this run.
  il_t "$a" snapshot >>"$d/ops.log" 2>&1 || fail "snapshot $a"
  il_report "$a" before || fail "lifecycle-report $a: $(tail -n 5 "$d/ops.log")"
  proxy="$(il_proxy "$d/before.tsv")"
  assert_match '^(haproxy|socat)$' "$proxy" "$a runs a standard deployment to install over"
  assert_eq standard "$(il_val "$d/before.tsv" generation pihole)" "and it is the standard one"
  printf 'cell\t%s/%s/hardened\nproxy\t%s\nsource_sha\t%s\nhardened_sha\t%s\nentrypoint\t%s\nadapter\t%s\n' \
    "$plat" "$proxy" "$proxy" "$(il_sha)" "$(git -C "$IH_SIB" rev-parse HEAD)" "$ent" \
    "$( [ -n "${NICE_DNS_TARGET_ADAPTER:-}" ] && echo fake || echo real)" >"$d/cell.tsv"

  il_install "$a" hardened install hardened || fail "the hardened install failed: $(tail -n 20 "$d/install-hardened.log")"
  il_watch_pinned "$plat" "$d/watch-hardened.tsv" all
  il_report "$a" after-hardened || fail "lifecycle-report"
  r="$d/after-hardened.tsv"
  il_check_deployed "$plat" "$r" "$proxy"
  assert_eq hardened "$(il_val "$r" generation pihole)" "the generation is the hardened Pi-hole"
  assert_eq "$ent" "$(il_val "$r" generation entrypoint)" "installed by $ent"

  il_install "$a" hardened-uninstall uninstall hardened || fail "the hardened uninstall failed: $(tail -n 20 "$d/install-hardened-uninstall.log")"
  il_report "$a" after-uninstall || fail "lifecycle-report"
  il_assert_uninstalled "$plat" "$d/before.tsv" "$d/after-uninstall.tsv"

  il_install "$a" standard install || fail "the standard install failed: $(tail -n 20 "$d/install-standard.log")"
  il_watch_pinned "$plat" "$d/watch-standard.tsv" after-first
  il_report "$a" after-standard || fail "lifecycle-report"
  il_check_deployed "$plat" "$d/after-standard.tsv" "$proxy"
  assert_eq standard "$(il_val "$d/after-standard.tsv" generation pihole)" "the target ends on the standard Pi-hole"
  printf 'entrypoint\t%s\tpass\n' "$ent" >"$d/entrypoint.tsv"
}

t_1_hardened_entrypoints() { il_selection; il_each il_hardened; }

t_2_evidence_is_private() {
  il_selection
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$ARTIFACT_DIR/install-hardened" --include='*.tsv' 2>/dev/null)" \
    "no report, sample or step record holds bridge material, a session or a hash"
}
