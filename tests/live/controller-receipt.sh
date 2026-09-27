# shellcheck shell=bash
# Group live/controller-receipt (Sub-plan 3; ARCH-09). The last row of plan
# controller: assembles <artifact root>/receipts/controller/RUN_ID/ from this
# run's live/controller-active cells and live/controller-wake evidence and
# verifies it (--require-platforms all, the transport receipt linked; under
# --matrix all also every proxy on every platform, with the hardened cells
# recorded blocked by scope: the representative gate, user decision
# 2026-09-26). A cell that did not pass is recorded failed, and what the run
# did not prove is recorded as a limit row. It observes nothing itself.

# shellcheck source=tests/live/controller-lib.sh
. "$NICE_DNS_ROOT/tests/live/controller-lib.sh"

ca_matrix_all() { [ "${NICE_DNS_OPT_MATRIX:-}" = all ]; }

# ─────────────────────────── receipt ────────────────────────────────────────

t_1_receipt() {
  local root out r t repo cd st d key gen cell id f n=0 v req
  CA_ROOT_DIR="$ARTIFACT_DIR/controller-active"
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  out="$root/receipts/controller/$RUN_ID"; r="$out/receipt.tsv"
  t="$(for t in "$root"/receipts/transport/*/receipt.tsv; do [ -f "$t" ] && printf '%s\n' "$t"; done | LC_ALL=C sort | tail -1)"
  assert_ne "" "$t" "a transport receipt exists to link"
  assert_file "$CA_ROOT_DIR/wake.txt" "the wake scenario ran in this run"
  assert_no_path "$out" "this run has no controller receipt yet"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tcontroller\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$NICE_DNS_ROOT"; else cd="$CS_SIBS/$repo"; fi
      if [ -n "$(cs_clean "$cd")" ]; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$CS_SIBS/$repo" rev-parse HEAD)" \
        "$(git -C "$CS_SIBS/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'requires\ttransport\t%s\t%s\n' "$t" "$(sha256sum "$t" | cut -d' ' -f1)"
  } >"$r"
  cp "$CA_ROOT_DIR/wake.txt" "$out/CT-WAKE.txt"
  printf 'scenario\tCT-WAKE\t-\tpass\tCT-WAKE.txt\t%s\t-\n' "$(sha256sum "$out/CT-WAKE.txt" | cut -d' ' -f1)" >>"$r"
  # This run's cells, then the cells carried from earlier runs (DEC-009:
  # controller-active skipped them and listed them in reused.tsv).
  : >"$CASE_DIR/cell-dirs.tsv"
  for d in "$CA_ROOT_DIR"/*-*-*/; do printf '%s\t-\n' "${d%/}" >>"$CASE_DIR/cell-dirs.tsv"; done
  if [ -f "$CA_ROOT_DIR/reused.tsv" ]; then
    while IFS="$(printf '\t')" read -r cell d; do
      [ -d "$d" ] || fail "reused cell $cell: no directory $d"
      printf '%s\t%s\n' "$d" "$(basename "$(dirname "$(dirname "$d")")")" >>"$CASE_DIR/cell-dirs.tsv"
    done <"$CA_ROOT_DIR/reused.tsv"
  fi
  while IFS="$(printf '\t')" read -r d from; do
    [ -f "$d/cell.tsv" ] || continue
    cell="$(awk -F '\t' '$1 == "cell" { print $2 }' "$d/cell.tsv")"
    key="$(printf '%s' "$cell" | tr / -)"
    gen="$(awk -F '\t' '$1 == "image_gen" { print $2 }' "$d/cell.tsv")"
    mkdir -p "$out/cells/$key"
    for f in cell.tsv observations.tsv; do [ -f "$d/$f" ] && cp "$d/$f" "$out/cells/$key/"; done
    # A cell that did not pass all six scenarios stays in the denominator as
    # failed, and the receipt then never verifies (ARCH-09; close-out M3).
    if [ "$(grep -c pass "$d/observations.tsv" 2>/dev/null)" -ne 6 ]; then
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" \
        "$(awk -F '\t' '$1 == "target" { print $2 }' "$d/cell.tsv")" "$gen" >>"$r"
      continue
    fi
    n=$((n + 1))
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" \
      "$(awk -F '\t' '$1 == "target" { print $2 }' "$d/cell.tsv")" "$gen" >>"$r"
    [ "$from" = - ] || printf 'reuse\t%s\t%s\t%s\n' "$cell" "$from" "$(awk -F '\t' '$1 == "nice_dns" { print $2; exit }' "$d/cell.tsv")" >>"$r"
    while IFS="$(printf '\t')" read -r id st f; do
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\t%s\tcells/%s/%s\t%s\t%s\n' "$id" "$cell" "$st" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done <"$d/observations.tsv"
    # What this cell did not prove (close-out M4). Readiness is corroborated
    # host-side only by an Unbound image with probe-route (DEC-006).
    if grep -q 'uncorroborated' "$d/recovery-ack.txt" 2>/dev/null; then
      printf 'limit\tready-corroboration\t%s\tscope=sub-plan-4\treadiness was not corroborated through Unbound: the deployed Unbound image has no probe-route\n' "$cell" >>"$r"
    elif ! grep -q '	ready	' "$d/recovery-ack.txt" 2>/dev/null; then
      printf 'limit\tready-corroboration\t%s\tscope=sub-plan-4\tthe recovery evidence holds no ready row\n' "$cell" >>"$r"
    fi
  done <"$CASE_DIR/cell-dirs.tsv"
  # A route switch is proven live only by an acknowledged route:* journal row;
  # before Sub-plan 4 mounts /etc/unbound/route every switch is unmanaged.
  if ! cut -f1 "$CASE_DIR/cell-dirs.tsv" | while IFS= read -r d; do cat "$d"/*.txt 2>/dev/null; done | awk -F '\t' '$3 ~ /^route:/ && $4 == "acknowledged" { f = 1 } END { exit !f }'; then
    printf 'limit\troute-apply\t-\tscope=sub-plan-4\tno switch-route was applied live: no deployment mounts /etc/unbound/route, so the result is unmanaged; route application rests on the transport receipt\n' >>"$r"
  fi
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  req=(--require-platforms all --require-dep transport)
  if ca_matrix_all; then
    # The representative gate (user decision 2026-09-26): every proxy on
    # every platform with standard Pi-hole; the hardened cells are Sub-plan
    # 5's final matrix, recorded here as blocked by scope, never as passed.
    req+=(--require-proxies all --require-platform-proxies all)
    for p in linux macos; do for x in haproxy socat; do
      awk -F '\t' -v p="$p" -v x="$x" '$1 == "cell" && $2 == p && $3 == x && $4 == "hardened" { f = 1 } END { exit !f }' "$r" \
        || printf 'cell\t%s\t%s\thardened\tscope\tscope=sub-plan-5\tblocked\n' "$p" "$x" >>"$r"
    done; done
  fi
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" "${req[@]}" 2>&1)"
  assert_rc 0 "$?" "the controller receipt verifies: $v"
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|pwhash|BRIDGE[0-9]+=' "$out" "$CA_ROOT_DIR" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key or password hash in the receipt or the evidence"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}
