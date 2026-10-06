# shellcheck shell=bash
# Group live/qualification-receipt (sub-plan 05 Task 2.3, Stage 2 gate;
# ARCH-09). The last row of plan qualification: assembles
# <artifact root>/receipts/qualification/RUN_ID/ from this run's
# live/qualification-cells evidence, links the newest baseline, transport,
# controller and installers receipts and the soak receipt (live/soak-receipt
# in this run), and verifies it with --require-matrix all. It observes
# nothing on a target; it checks the evidence it copies:
#
#   QU-COLD-START    per cell: cold-start.tsv says pass, no manual repair
#   QU-NO-DIRECT     per cell: no-direct/verdict.tsv, violations 0
#   QU-NETWORK-LOSS  per cell: network-loss/verdict.tsv, a first answer
#                    after the return, no manual repair
#
# A cell whose checks did not all finish stays in the receipt as failed, and
# the receipt then never verifies.
#
# Identity (Stage 2 gate reviews): every cell must have run this nice-dns
# HEAD and the sibling HEADs the receipt records (cell.tsv source_sha,
# proxy_sha, hardened_sha); the soak link is exactly the receipt
# live/soak-receipt verified in this run ($ARTIFACT_DIR/soak-receipt.tsv);
# the other links are the newest receipts of each name whose sources are
# all clean and which verify (a test run on a dirty tree can write one as a
# side effect). nice-dns itself must be clean.
# QR_REHEARSAL=1 with QR_CELLS_DIR (a dry run's evidence) rehearses the
# assembly: the receipt is written under the case directory, never under
# receipts/, and links the newest verified soak receipt.

QR_SIBS="${NICE_DNS_SIBLINGS_DIR:-$(dirname "$NICE_DNS_ROOT")}"

qr_get() { awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$2" 2>/dev/null; }
# qr_newest <root> <name>: the newest receipt of <name> with every source
# row clean that verifies on its own.
qr_newest() {
  local root="$1" n="$2" t c
  for t in $(for c in "$root"/receipts/"$n"/*/receipt.tsv; do [ -f "$c" ] && printf '%s\n' "$c"; done | LC_ALL=C sort -r); do
    awk -F '\t' '$1 == "source" && $4 != "clean" { d = 1 } END { exit d }' "$t" || continue
    bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$t" >/dev/null 2>&1 || continue
    printf '%s\n' "$t"; return 0
  done
}
qr_clean() { GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain | grep -v '^?? bridge-eval/bridge-eval$'; }

# qr_scenario <receipt> <out> <id> <key> <gen> <src file> <pass?>: copy the
# artifact into the receipt and record the scenario.
qr_scenario() {
  local r="$1" out="$2" id="$3" key="$4" gen="$5" src="$6" st="$7" rel
  rel="cells/${key//\//-}/$id.tsv"
  mkdir -p "$out/cells/${key//\//-}"
  if [ -f "$src" ]; then cp "$src" "$out/$rel"; else printf '# %s: no evidence (%s)\n' "$id" "$src" >"$out/$rel"; st=fail; fi
  printf 'scenario\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$key" "$st" "$rel" "$(sha256sum "$out/$rel" | cut -d' ' -f1)" "$gen" >>"$r"
}

t_1_qualification_receipt() {
  local root out r cells d key plat proxy ph alias gen st repo cd n t v sr
  root="$(dirname "$(dirname "$ARTIFACT_DIR")")"
  if [ "${QR_REHEARSAL:-}" = 1 ]; then
    cells="${QR_CELLS_DIR:?QR_REHEARSAL needs QR_CELLS_DIR}"; out="$CASE_DIR/rehearsal"
  else
    [ -z "${QR_CELLS_DIR:-}" ] || fail "QR_CELLS_DIR is for a rehearsal (QR_REHEARSAL=1) only"
    cells="$ARTIFACT_DIR/qualification-cells"; out="$root/receipts/qualification/$RUN_ID"
  fi
  [ -d "$cells" ] || fail "no qualification-cells evidence at $cells"
  [ -z "$(qr_clean "$NICE_DNS_ROOT")" ] || fail "nice-dns is not committed: the receipt names HEAD"
  r="$out/receipt.tsv"
  [ ! -e "$out" ] || fail "this run already has a qualification receipt at $out"
  mkdir -p "$out/cells" || fail "cannot create $out"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\tqualification\nrun_id\t%s\ncreated_utc\t%s\n' "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for repo in nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      if [ "$repo" = nice-dns ]; then cd="$NICE_DNS_ROOT"; else cd="$QR_SIBS/$repo"; fi
      if [ -n "$(qr_clean "$cd")" ]; then st=dirty; else st=clean; fi
      printf 'source\t%s\t%s\t%s\n' "$repo" "$(git -C "$cd" rev-parse HEAD)" "$st"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$QR_SIBS/$repo" rev-parse HEAD)" \
        "$(git -C "$QR_SIBS/$repo" show HEAD:.github/workflows/main.yml |
          awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
          sort | paste -sd, -)"
    done
    printf 'product\tnice-dns\t%s\n' "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)"
    printf 'product\tpi-hole-hardened\t%s\n' "$(git -C "$QR_SIBS/pi-hole-hardened" rev-parse HEAD)"
    for n in baseline transport controller installers soak; do
      if [ "$n" = soak ] && [ "${QR_REHEARSAL:-}" != 1 ]; then
        t="$(cat "$ARTIFACT_DIR/soak-receipt.tsv" 2>/dev/null)"
        [ -f "$t" ] || fail "no soak receipt from this run's live/soak-receipt"
      else
        t="$(qr_newest "$root" "$n")"
      fi
      [ -n "$t" ] || fail "no clean, verifying $n receipt to link"
      printf 'requires\t%s\t%s\t%s\n' "$n" "$t" "$(sha256sum "$t" | cut -d' ' -f1)"
    done
    printf 'limit\tlatency-per-platform\t-\tscope=sub-plan-5\tthe 24 h soak and latency are judged on one representative cell per platform (the linked soak receipt; user decisions 2026-10-06); the other cells are checked for cold start, no direct query and network loss, not for latency\n'
  } >"$r"
  sr="$(awk -F '\t' '$1 == "requires" && $2 == "soak" { print $3 }' "$r")"

  # The cells, every one of the matrix, observed only when all checks ran.
  n=0
  while IFS="$(printf '\t')" read -r plat proxy ph; do
    case "$plat" in ''|'#'*) continue ;; esac
    key="$plat/$proxy/$ph" n=$((n + 1))
    d="$(find "$cells" -mindepth 2 -maxdepth 2 -type d -name "$plat-$proxy-$ph" | head -1)"
    if [ -z "$d" ] || ! grep -qx 'checked	cold-start no-direct network-loss' "$d/cell.tsv" 2>/dev/null; then
      alias="${d:+$(basename "$(dirname "$d")")}"
      printf 'cell\t%s\t%s\t%s\t%s\t%s\tfailed\n' "$plat" "$proxy" "$ph" "${alias:-unobserved}" "generation=none" >>"$r"
      continue
    fi
    alias="$(basename "$(dirname "$d")")"
    gen="$(qr_get generation "$d/cell.tsv")"
    # The cell ran what this receipt names.
    [ "$(qr_get source_sha "$d/cell.tsv")" = "$(git -C "$NICE_DNS_ROOT" rev-parse HEAD)" ] \
      || fail "$key ran nice-dns $(qr_get source_sha "$d/cell.tsv"), not HEAD"
    [ "$(qr_get proxy_sha "$d/cell.tsv")" = "$(git -C "$QR_SIBS/tor-$proxy" rev-parse HEAD)" ] \
      || fail "$key ran tor-$proxy $(qr_get proxy_sha "$d/cell.tsv"), not its HEAD"
    if [ "$ph" = hardened ]; then
      [ "$(qr_get hardened_sha "$d/cell.tsv")" = "$(git -C "$QR_SIBS/pi-hole-hardened" rev-parse HEAD)" ] \
        || fail "$key ran pi-hole-hardened $(qr_get hardened_sha "$d/cell.tsv"), not its HEAD"
    fi
    _nd_tick
    printf 'cell\t%s\t%s\t%s\t%s\t%s\tobserved\n' "$plat" "$proxy" "$ph" "$alias" "$gen" >>"$r"
    st=fail; [ "$(qr_get cold_start "$d/cold-start.tsv")" = pass ] && [ "$(qr_get manual_repair "$d/cold-start.tsv")" = none ] && st=pass
    qr_scenario "$r" "$out" QU-COLD-START "$key" "$gen" "$d/cold-start.tsv" "$st"
    st=fail; [ "$(qr_get violations "$d/no-direct/verdict.tsv")" = 0 ] && st=pass
    qr_scenario "$r" "$out" QU-NO-DIRECT "$key" "$gen" "$d/no-direct/verdict.tsv" "$st"
    st=fail; [ -n "$(qr_get first_answer_after_return_s "$d/network-loss/verdict.tsv")" ] \
      && [ "$(qr_get manual_repair "$d/network-loss/verdict.tsv")" = none ] && st=pass
    qr_scenario "$r" "$out" QU-NETWORK-LOSS "$key" "$gen" "$d/network-loss/verdict.tsv" "$st"
  done <"$NICE_DNS_ROOT/tests/manifests/matrix.tsv"
  assert_eq 8 "$n" "the eight-cell matrix"
  v="$(bash "$NICE_DNS_ROOT/tests/reports/verify.sh" check "$r" --require-matrix all 2>&1)"
  assert_rc 0 $? "the qualification receipt verifies (--require-matrix all; soak receipt $sr): $v"
}
