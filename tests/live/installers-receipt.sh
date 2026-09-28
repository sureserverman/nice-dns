# shellcheck shell=bash
# Group live/installers-receipt (Sub-plan 4 Stage 2 gate; ARCH-09). The last
# row of plan installers: assembles <artifact root>/receipts/installers/RUN_ID/
# from this run's live/install-lifecycle cells (and the cells it reused,
# DEC-009), live/install-hardened entrypoints and the bootstrap inventory
# check of integration/installers-interaction, links the newest controller
# receipt and verifies the result (--require-platforms all
# --require-entrypoints all; under --matrix all also every proxy on every
# platform, the hardened cells recorded blocked by scope: Sub-plan 5). It
# observes nothing on a target; it checks the evidence it copies:
#
#   IN-OWNED-RESTORE  per cell: the uninstall step passed, and the report
#                     after it shows the host resolving on the recorded state
#   IN-NO-HOST-PUBLIC per cell: every resolver sample of the installs over a
#                     deployment is the stack; from a restored host, once the
#                     stack, always the stack
#   IN-BUNDLE         per cell: the running images are the generation's, the
#                     controller bundle is the one this source builds, and a
#                     reinstall kept the previous generation for rollback
#   IN-BOOTSTRAP      global: the inventory check passed in this run (a
#                     fixture check; the live installs' network calls are not
#                     traced, recorded as a limit)
#
# A cell that did not pass stays in the receipt as failed, and the receipt
# then never verifies.

# shellcheck source=tests/live/install-lifecycle.sh
. "$NICE_DNS_ROOT/tests/live/install-lifecycle.sh"
unset -f t_1_before t_2_upgrade_from_legacy t_3_state_survives t_4_uninstall_restores t_5_final_install t_6_evidence_is_private

IR_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"
IR_STEPS='il_before il_upgrade il_state il_uninstall il_final'

ir_adapter() { if [ -n "${NICE_DNS_TARGET_ADAPTER:-}" ]; then echo fake; else echo real; fi; }
ir_clean() { GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain | grep -v '^?? bridge-eval/bridge-eval$'; }

# ir_expected_bundle <sha>: the controller bundle id that nice-dns at <sha>
# installs (health/nice-dns-health build_bundle: each file's name and sha256,
# hashed, first 16 hex).
ir_expected_bundle() {
  local s="$1" files f
  files="$(git -C "$NICE_DNS_ROOT" show "$s:health/nice-dns-health" | sed -n 's/^HEALTH_LIB_FILES="\(.*\)"$/\1/p')"
  [ -n "$files" ] || return 1
  for f in $files health/nice-dns-health; do
    printf '%s\n' "$f"
    git -C "$NICE_DNS_ROOT" show "$s:$f" | sha256sum | cut -d' ' -f1
  done | sha256sum | cut -c1-16
}

# ir_results_pass <run dir> <kind/group>: every row of that group passed, and
# there was at least one.
ir_results_pass() {
  awk -F '\t' -v g="$2" '$1 == g { n++; if ($4 != "pass") bad = 1 } END { exit !(n >= 1 && !bad) }' "$1/results.tsv" 2>/dev/null
}

# ir_cell_passed <cell dir> <from>: this run's cell passed every step and the
# privacy case; a reused one was checked at reuse (il_reusable).
ir_cell_passed() {
  local d="$1" from="$2" s
  if [ "$from" != - ]; then return 0; fi
  for s in $IR_STEPS; do grep -qx "$s" "$d/passed.tsv" 2>/dev/null || return 1; done
  awk -F '\t' '$1 == "live/install-lifecycle" && $3 == "t_6_evidence_is_private" && $4 == "pass" { f = 1 } END { exit !f }' "$ARTIFACT_DIR/results.tsv"
}

# ir_evidence <cell dir> <out dir> <cell>: the three per-cell scenario files;
# prints "ID<TAB>pass|fail<TAB>file" rows.
ir_evidence() {
  local d="$1" o="$2" plat="${3%%/*}" f st sha want got s mode c role t
  # IN-OWNED-RESTORE
  f="$o/owned-restore.tsv"
  { awk -F '\t' '{ print "before\t" $0 }' < <(il_sec "$d/before.tsv" dns)
    awk -F '\t' '{ print "after-uninstall\t" $0 }' < <(il_sec "$d/after-uninstall.tsv" dns; il_sec "$d/after-uninstall.tsv" resolution)
    awk -F '\t' '$1 == "uninstall" { print "step\t" $0 }' "$d/steps.tsv"; } >"$f"
  st=fail
  if [ "$(il_val "$d/after-uninstall.tsv" resolution resolves)" = yes ] && grep -q '^step	uninstall	uninstall	0$' "$f" \
    && [ -z "$(il_sec "$d/after-uninstall.tsv" volumes)" ] && [ -z "$(il_sec "$d/after-uninstall.tsv" running | awk -F '\t' '$1 == "running"')" ]; then
    if [ "$plat" = linux ]; then
      il_sec "$d/after-uninstall.tsv" dns | grep -q '^resolv\.conf	/run/systemd/resolve/stub-resolv\.conf$' && st=pass
    else
      [ -z "$(il_sec "$d/after-uninstall.tsv" dns | awk -F '\t' 'NF >= 2 && $2 ~ /172\.31\.240\.250/')" ] && st=pass
    fi
  fi
  printf 'IN-OWNED-RESTORE\t%s\towned-restore.tsv\n' "$st"
  # IN-NO-HOST-PUBLIC: il_watch_pinned's rule, re-applied to the copies.
  f="$o/resolver-samples.tsv"
  : >"$f"
  # Only the samples taken up to the report that followed the install: a
  # watcher that outlived its step (before il_stop_watch) kept sampling the
  # later steps, the uninstall among them.
  for s in upgrade reinstall final; do
    t="$(awk -F '\t' '$1 == "now" { print $2; exit }' "$d/after-$s.tsv")"
    [ -n "$t" ] && [ -f "$d/watch-$s.tsv" ] && awk -F '\t' -v s="$s" -v t="$t" 'NF >= 2 && $1 <= t { print s "\t" $0 }' "$d/watch-$s.tsv" >>"$f"
  done
  st=pass
  for s in upgrade reinstall final; do
    mode=after-first
    { [ "$s" = reinstall ] || { [ "$s" = upgrade ] && [ -n "$(il_proxy "$d/before.tsv")" ]; }; } && mode=all
    ( il_watch_pinned "$plat" <(awk -F '\t' -v s="$s" '$1 == s { sub(/^[^\t]*\t/, ""); print }' "$f") "$mode" ) >/dev/null 2>&1 || st=fail
  done
  printf 'IN-NO-HOST-PUBLIC\t%s\tresolver-samples.tsv\n' "$st"
  # IN-BUNDLE
  f="$o/bundle.tsv"
  sha="$(awk -F '\t' '$1 == "source_sha" { print $2; exit }' "$d/cell.tsv")"
  want="$(ir_expected_bundle "$sha")" || want=unknown
  { printf 'source_sha\t%s\nexpected_bundle\t%s\n' "$sha" "$want"
    for s in after-reinstall after-final; do
      il_sec "$d/$s.tsv" generation | awk -F '\t' -v s="$s" '$1 ~ /^(current|entrypoint|pihole|variant|previous|rollback|image)$/ { print s "\tgeneration\t" $0 }'
      il_sec "$d/$s.tsv" controller | awk -F '\t' -v s="$s" '$1 == "bundle" || $1 == "mode" { print s "\tcontroller\t" $0 }'
      il_sec "$d/$s.tsv" running | awk -F '\t' -v s="$s" '$1 == "running" { print s "\trunning\t" $0 }'
    done; } >"$f"
  st=pass
  for s in after-reinstall after-final; do
    got="$(il_val "$d/$s.tsv" controller bundle)"
    [ -n "$got" ] && [ "$got" = "$want" ] || st=fail
    for c in pi-hole unbound "tor-$(il_cell_of "$d" proxy)"; do
      case "$c" in tor-*) role=proxy ;; *) role="$c" ;; esac
      [ "$(il_val3 "$d/$s.tsv" running running "$c" | sed 's/^sha256://')" = \
        "$(il_sec "$d/$s.tsv" generation | awk -F '\t' -v k="$role" '$1 == "image" && $2 == k { print $4; exit }' | sed 's/^sha256://')" ] || st=fail
    done
  done
  il_sec "$d/after-reinstall.tsv" generation | awk -F '\t' '$1 == "rollback" && $3 == "available" { f = 1 } END { exit !f }' || st=fail
  printf 'IN-BUNDLE\t%s\tbundle.tsv\n' "$st"
}

il_cell_of() { awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1/cell.tsv"; }

ir_receipt() {
  local root out r t repo cd st d from cell key gen n=0 v req id f p e a src ent
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/installers/$RUN_ID"; r="$out/receipt.tsv"
  t="$(for t in "${NICE_DNS_IR_CONTROLLER_ROOT:-$root}"/receipts/controller/*/receipt.tsv; do [ -f "$t" ] && printf '%s\n' "$t"; done | LC_ALL=C sort | tail -1)"
  assert_ne "" "$t" "a controller receipt exists to link"
  assert_no_path "$out" "this run has no installers receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tinstallers\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$NICE_DNS_ROOT"; else cd="$IR_SIBS/$repo"; fi
      if [ -n "$(ir_clean "$cd")" ]; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$IR_SIBS/$repo" rev-parse HEAD)" \
        "$(git -C "$IR_SIBS/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'product\tnice-dns\t%s\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
    printf 'product\tpi-hole-hardened\t%s\n' "$(git -C "$IR_SIBS/pi-hole-hardened" rev-parse HEAD)"
    printf 'requires\tcontroller\t%s\t%s\n' "$t" "$(sha256sum "$t" | cut -d' ' -f1)"
  } >"$r"

  # IN-BOOTSTRAP: the inventory check of this run.
  f="$out/IN-BOOTSTRAP.txt"
  src="$ARTIFACT_DIR/cases/integration-installers-interaction/t_bootstrap_use_is_declared/case.log"
  if awk -F '\t' '$1 == "integration/installers-interaction" && $3 == "t_bootstrap_use_is_declared" && $4 == "pass" { f = 1 } END { exit !f }' "$ARTIFACT_DIR/results.tsv" 2>/dev/null && [ -f "$src" ]; then
    { printf '# integration/installers-interaction t_bootstrap_use_is_declared: pass (run %s)\n' "$RUN_ID"; cat "$NICE_DNS_ROOT/release/bootstrap.tsv"; printf '# case log\n'; cat "$src"; } >"$f"
    st=pass
  else
    printf '# integration/installers-interaction t_bootstrap_use_is_declared did not pass in run %s\n' "$RUN_ID" >"$f"; st=fail
  fi
  printf 'scenario\tIN-BOOTSTRAP\t-\t%s\tIN-BOOTSTRAP.txt\t%s\t-\n' "$st" "$(sha256sum "$f" | cut -d' ' -f1)" >>"$r"
  printf 'limit\tbootstrap-live\t-\tscope=sub-plan-5\tthe live installs'"'"' network calls were not traced; IN-BOOTSTRAP rests on the inventory check and the resolver samples\n' >>"$r"

  # This run's cells, then the reused ones.
  : >"$CASE_DIR/cell-dirs.tsv"
  for d in "$ARTIFACT_DIR"/install-lifecycle/*/; do
    [ -f "$d/cell.tsv" ] || continue
    [ "$(il_cell_of "$d" adapter)" = "$(ir_adapter)" ] || continue
    printf '%s\t-\n' "${d%/}" >>"$CASE_DIR/cell-dirs.tsv"
  done
  for f in "$ARTIFACT_DIR"/install-lifecycle/reused-*.tsv; do
    [ -f "$f" ] || continue
    while IFS="$(printf '\t')" read -r cell d; do
      [ -d "$d" ] || fail "reused cell $cell: no directory $d"
      printf '%s\t%s\n' "$d" "$(basename "$(dirname "$(dirname "$d")")")" >>"$CASE_DIR/cell-dirs.tsv"
    done <"$f"
  done
  while IFS="$(printf '\t')" read -r d from; do
    cell="$(il_cell_of "$d" cell)"; key="$(printf '%s' "$cell" | tr / -)"
    gen="generation=$(il_val "$d/after-final.tsv" generation current)"
    a="$(basename "$d")"
    mkdir -p "$out/cells/$key"
    cp "$d/cell.tsv" "$out/cells/$key/"
    if ! ir_cell_passed "$d" "$from"; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" "$a" "$gen" >>"$r"
    [ "$from" = - ] || printf 'reuse\t%s\t%s\t%s\n' "$cell" "$from" "$(il_cell_of "$d" source_sha)" >>"$r"
    while IFS="$(printf '\t')" read -r id st f; do
      printf 'scenario\t%s\t%s\t%s\tcells/%s/%s\t%s\t%s\n' "$id" "$cell" "$st" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done < <(ir_evidence "$d" "$out/cells/$key" "$cell")
  done <"$CASE_DIR/cell-dirs.tsv"
  assert_match '^[1-9]' "$n" "at least one fully passed cell"

  # Entrypoints: the standard ones by their platform's cells, the hardened
  # ones by live/install-hardened (this run, or a reused run).
  for p in linux macos; do
    case "$p" in linux) e=install-deb.sh ;; *) e=install-mac.sh ;; esac
    if awk -F '\t' -v p="$p" '$1 == "cell" && $2 == p && $4 == "standard" { if ($7 == "observed") ok = 1; else bad = 1 } END { exit !(ok && !bad) }' "$r"; then
      printf 'entrypoint\t%s\tpass\n' "$e" >>"$r"
    else printf 'entrypoint\t%s\tfail\n' "$e" >>"$r"; fi
  done
  for e in install-deb-hardened.sh install-mac-hardened.sh; do
    st=fail
    for src in "$ARTIFACT_DIR" ${NICE_DNS_CELL_REUSE_RUNS:-}; do
      ir_results_pass "$src" live/install-hardened || continue
      for f in "$src"/install-hardened/*/entrypoint.tsv; do
        [ -f "$f" ] || continue
        ent="$(awk -F '\t' '$1 == "entrypoint" && $3 == "pass" { print $2 }' "$f")"
        [ "$ent" = "$e" ] || continue
        [ "$(il_cell_of "$(dirname "$f")" adapter)" = "$(ir_adapter)" ] || continue
        il_same_product "$(il_cell_of "$(dirname "$f")" source_sha)" "$(il_cell_of "$(dirname "$f")" cell | cut -d/ -f1)" || continue
        [ "$(il_cell_of "$(dirname "$f")" hardened_sha)" = "$(git -C "$IR_SIBS/pi-hole-hardened" rev-parse HEAD)" ] || continue
        st=pass; mkdir -p "$out/entrypoints"; cp "$f" "$out/entrypoints/$e.tsv"
      done
      [ "$st" = pass ] && break
    done
    printf 'entrypoint\t%s\t%s\n' "$e" "$st" >>"$r"
  done
  printf 'limit\tlegacy-profile-pin-restore\t-\tscope=sub-plan-4\tthe restore of a legacy NetworkManager profile pin is proven in the fixture only: mint'"'"'s legacy pin was reset by hand before the fix could run\n' >>"$r"

  req=(--require-platforms all --require-dep controller --require-entrypoints all)
  if il_gate; then
    # The representative gate (user decision 2026-09-26): every proxy on
    # every platform with standard Pi-hole; the hardened cells are Sub-plan
    # 5's final matrix, recorded here as blocked by scope, never as passed.
    req+=(--require-proxies all --require-platform-proxies all)
    for p in linux macos; do for x in haproxy socat; do
      printf 'cell\t%s\t%s\thardened\tscope\tscope=sub-plan-5\tblocked\n' "$p" "$x" >>"$r"
    done; done
  fi
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" "${req[@]}" 2>&1)"
  assert_rc 0 "$?" "the installers receipt verifies: $v"
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|"sid":|pwhash|BRIDGE[0-9]+=' "$out" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key, session or password hash in the receipt"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}

t_1_receipt() { il_selection; ir_receipt; }
