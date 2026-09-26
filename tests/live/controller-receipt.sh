# shellcheck shell=bash
# Group live/controller-receipt (Sub-plan 3; ARCH-09). The last row of plan
# controller: assembles <artifact root>/receipts/controller/RUN_ID/ from this
# run's live/controller-active cells and live/controller-wake evidence and
# verifies it (--require-platforms all, the transport receipt linked;
# --require-matrix all under --matrix all). It observes nothing itself.

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
  for d in "$CA_ROOT_DIR"/*-*-*/; do
    [ -f "$d/cell.tsv" ] || continue
    cell="$(awk -F '\t' '$1 == "cell" { print $2 }' "$d/cell.tsv")"
    key="$(printf '%s' "$cell" | tr / -)"
    gen="$(awk -F '\t' '$1 == "image_gen" { print $2 }' "$d/cell.tsv")"
    [ "$(grep -c pass "$d/observations.tsv")" -eq 6 ] || continue
    n=$((n + 1))
    mkdir -p "$out/cells/$key"
    for f in cell.tsv observations.tsv; do cp "$d/$f" "$out/cells/$key/"; done
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "${cell%%/*}" "$(printf '%s' "$cell" | cut -d/ -f2)" "${cell##*/}" \
      "$(awk -F '\t' '$1 == "target" { print $2 }' "$d/cell.tsv")" "$gen" >>"$r"
    while IFS="$(printf '\t')" read -r id st f; do
      cp "$d/$f" "$out/cells/$key/$f"
      printf 'scenario\t%s\t%s\t%s\tcells/%s/%s\t%s\t%s\n' "$id" "$cell" "$st" "$key" "$f" "$(sha256sum "$out/cells/$key/$f" | cut -d' ' -f1)" "$gen" >>"$r"
    done <"$d/observations.tsv"
  done
  assert_match '^[1-9]' "$n" "at least one fully passed cell"
  req=(--require-platforms all --require-dep transport)
  ca_matrix_all && req+=(--require-matrix all)
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" "${req[@]}" 2>&1)"
  assert_rc 0 "$?" "the controller receipt verifies: $v"
  assert_eq "" "$(grep -rlE 'cert=[A-Za-z0-9+/]{20}|(^|[^0-9A-Fa-f])[0-9A-F]{40}([^0-9A-Fa-f]|$)|PRIVATE KEY|pwhash|BRIDGE[0-9]+=' "$out" "$CA_ROOT_DIR" 2>/dev/null)" \
    "no bridge line, certificate, fingerprint, key or password hash in the receipt or the evidence"
  printf 'receipt\t%s\n' "$r" >"$CASE_DIR/receipt-path.tsv"
}
