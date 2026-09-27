# shellcheck shell=bash
# Group unit/receipt-verifier (sub-plan 01, Task 2.2; ARCH-09).
#
# Builds synthetic receipts from the receipt manifests and checks that
# tests/reports/verify.sh accepts a complete one and refuses a missing
# scenario, a skipped or blocked cell, a wrong image generation, a tampered
# artifact or aggregate, a dropped CPU platform, a broken dependency link and
# any unknown receipt, row type or scenario id.

RV="$NICE_DNS_ROOT/tests/reports/verify.sh"
RV_MAN="$NICE_DNS_ROOT/tests/manifests"
RV_SIB="$(cd "$NICE_DNS_ROOT/.." && pwd -P)"
RV_REPOS="nice-dns tor-haproxy tor-socat hardened-unbound pi-hole-hardened"

rv_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

rv_platforms() {
  # Source-defined platforms of a sibling at HEAD, comma-joined and sorted.
  git -C "$RV_SIB/$1" show HEAD:.github/workflows/main.yml |
    awk '/^ *platform: *$/ { on = 1; next } on && /^ *- *linux\// { sub(/^ *- */, ""); print; next } on { on = 0 }' |
    sort | paste -sd, -
}

rv_artifact() {
  # rv_artifact NAME SCENARIO CELLKEY|- GEN FILE: content that satisfies the
  # manifest's minimum/content rules for SCENARIO (samples carry the cell).
  local name="$1" sc="$2" key="$3" gen="$4" out="$5" min head
  head="$(git -C "$RV_SIB/nice-dns" rev-parse HEAD)"
  min="$(awk -F '\t' -v s="$sc" '$1 == "minimum" && $2 == s { print $3 }' "$RV_MAN/$name.tsv")"
  if [ -n "$min" ]; then
    awk -v n="$min" -v run="run-test-$name" -v rev="$head" -v key="$key" -v gen="$gen" 'BEGIN {
      split(key, c, "/")
      printf "# schema\tnice-dns-sample/1\n"
      print "run_id\tsample_id\tutc_start\telapsed_us\tworkload\tcache_class\ttarget_id\tplatform\tproxy\tpihole\tsource_rev\timages\tresolver\ttransport\tqname\tqtype\toutcome\trcode\ttimeout_ms"
      for (i = 1; i <= n; i++)
        printf "%s\t%d\t2026-01-01T00:00:00Z\t1500\tcold\tmiss\ttarget-%s\t%s\t%s\t%s\t%s\t%s\t127.0.0.1#53\tudp\tq.example.com\tA\tok\tNOERROR\t5000\n", run, i, c[1], c[1], c[2], c[3], rev, gen
    }' >"$out"
    return
  fi
  case "$name:$sc" in
    baseline:BL-STAGE) printf 'git_head\t%s\ncollected=1 passed=1 failed=0\nresult=pass run_id=x\n' "$head" ;;
    baseline:BL-INVENTORY) printf 'repo\tnice-dns\n' ;;
    baseline:BL-CONFIG) printf 'image\tpi-hole\tpi-hole:latest\tsha256:0\n' ;;
    baseline:BL-SEVERED) printf 'health\tpodman:unbound\thealthy\t-\n' ;;
    baseline:BL-RESTORED) printf 'pi-hole\trunning\t-\n' ;;
    baseline:BL-TARGETS) printf 'coverage\t8 cells\n' ;;
    *) printf 'observed %s %s\n' "$sc" "$key" ;;
  esac >"$out"
  # Every anchored literal content rule (^text$) of the manifest, so a rule
  # added to a manifest is satisfied here without a hand-kept copy.
  awk -F '\t' -v s="$sc" '$1 == "content" && $2 == s && $3 ~ /^\^[^][\\.*+?(){}|^$]*\$$/ {
    print substr($3, 2, length($3) - 2) }' "$RV_MAN/$name.tsv" >>"$out"
}

rv_build() {
  # rv_build <receipt-name> <dir> [cells: all|rep]: a complete, valid receipt.
  local name="$1" d="$2" cells="${3:-all}" r p x h key gen sc scope a repo
  mkdir -p "$d/art"
  r="$d/receipt.tsv"
  {
    printf '# schema\tnice-dns-receipt/1\n'
    printf 'receipt\t%s\nrun_id\trun-test-%s\ncreated_utc\t2026-09-22T00:00:00Z\n' "$name" "$name"
    for repo in $RV_REPOS; do
      printf 'source\t%s\t%s\tclean\n' "$repo" "$(git -C "$RV_SIB/$repo" rev-parse HEAD)"
    done
    for repo in tor-haproxy tor-socat hardened-unbound pi-hole-hardened; do
      printf 'arch\t%s\t%s\t%s\n' "$repo" "$(git -C "$RV_SIB/$repo" rev-parse HEAD)" "$(rv_platforms "$repo")"
    done
  } >"$r"
  for a in $(awk -F '\t' '$1 == "requires" { print $2 }' "$RV_MAN/$name.tsv"); do
    rv_build "$a" "$d/dep-$a" "$cells"
    printf 'requires\t%s\t%s\t%s\n' "$a" "$d/dep-$a/receipt.tsv" "$(rv_sha "$d/dep-$a/receipt.tsv")" >>"$r"
  done
  while IFS='	' read -r p x h; do
    case "$p" in ''|'#'*) continue ;; esac
    if [ "$cells" = rep ] && [ "$x/$h" != haproxy/standard ]; then continue; fi
    printf 'cell\t%s\t%s\t%s\ttarget-%s\tpihole=sha256:%s1;unbound=sha256:%s2;proxy=sha256:%s3\tobserved\n' \
      "$p" "$x" "$h" "$p" "$p$x$h" "$p$x$h" "$p$x$h" >>"$r"
  done <"$RV_MAN/matrix.tsv"
  while IFS='	' read -r a sc scope _; do
    [ "$a" = scenario ] || continue
    if [ "$scope" = global ]; then
      rv_artifact "$name" "$sc" - - "$d/art/$sc.txt"
      printf 'scenario\t%s\t-\tpass\tart/%s.txt\t%s\t-\n' "$sc" "$sc" "$(rv_sha "$d/art/$sc.txt")" >>"$r"
    else
      awk -F '\t' '$1 == "cell" { print $2 "/" $3 "/" $4 "\t" $6 }' "$r" | while IFS='	' read -r key gen; do
        rv_artifact "$name" "$sc" "$key" "$gen" "$d/art/$sc-$(printf '%s' "$key" | tr / -).txt"
        printf 'scenario\t%s\t%s\tpass\tart/%s-%s.txt\t%s\t%s\n' "$sc" "$key" "$sc" "$(printf '%s' "$key" | tr / -)" \
          "$(rv_sha "$d/art/$sc-$(printf '%s' "$key" | tr / -).txt")" "$gen" >>"$r"
      done
    fi
  done <"$RV_MAN/$name.tsv"
  # One real aggregate: stats over a small sample file.
  {
    printf '# schema\tnice-dns-sample/1\n'
    printf 'run_id\tsample_id\tutc_start\telapsed_us\tworkload\tcache_class\ttarget_id\tplatform\tproxy\tpihole\tsource_rev\timages\tresolver\ttransport\tqname\tqtype\toutcome\trcode\ttimeout_ms\n'
    printf 'run-test-%s\t1\t2026-01-01T00:00:00Z\t1500\tcold\tmiss\tt\tlinux\thaproxy\tstandard\t%s\ti\t127.0.0.1#53\tudp\ta.example.com\tA\tnxdomain\tNXDOMAIN\t5000\n' "$name" "$(git -C "$RV_SIB/nice-dns" rev-parse HEAD)"
    printf 'run-test-%s\t2\t2026-01-01T00:00:01Z\t5000000\tcold\tmiss\tt\tlinux\thaproxy\tstandard\t%s\ti\t127.0.0.1#53\tudp\tb.example.com\tA\ttimeout\t-\t5000\n' "$name" "$(git -C "$RV_SIB/nice-dns" rev-parse HEAD)"
  } >"$d/art/samples.tsv"
  bash "$NICE_DNS_ROOT/tests/reports/stats.sh" "$d/art/samples.tsv" >"$d/art/stats.tsv"
  printf 'aggregate\tart/stats.tsv\t%s\tart/samples.tsv\n' "$(rv_sha "$d/art/stats.tsv")" >>"$r"
}

rv() {
  RV_OUT="$(bash "$RV" check "$@" 2>&1)"
  RV_RC=$?
}

rv_edit() {
  # rv_edit <receipt> <awk program>: rewrite the receipt in place.
  awk -F '\t' -v OFS='\t' "$2" "$1" >"$1.new" && mv "$1.new" "$1"
}

t_complete_baseline_receipt_verifies() {
  rv_build baseline "$CASE_DIR/b"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_rc 0 "$RV_RC" "complete eight-cell baseline: $RV_OUT"
  assert_match 'cells=8' "$RV_OUT" "reports eight observed cells"
}

t_each_missing_scenario_fails() {
  local sc n=0
  for sc in $(awk -F '\t' '$1 == "scenario" { print $2 }' "$RV_MAN/baseline.tsv"); do
    n=$((n + 1))
    rm -rf "$CASE_DIR/b"
    rv_build baseline "$CASE_DIR/b"
    # Remove one row of that scenario (one cell's row for a per-cell scenario).
    rv_edit "$CASE_DIR/b/receipt.tsv" "\$1 == \"scenario\" && \$2 == \"$sc\" && !done { done = 1; next } { print }"
    rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
    assert_nonzero "$RV_RC" "receipt without one $sc row"
    assert_match "$sc" "$RV_OUT" "failure names $sc"
  done
  assert_eq 8 "$n" "all baseline scenarios exercised"
}

t_skipped_or_blocked_cell_fails_under_full_matrix() {
  rv_build baseline "$CASE_DIR/b"
  cp "$CASE_DIR/b/receipt.tsv" "$CASE_DIR/orig.tsv"
  rv_edit "$CASE_DIR/b/receipt.tsv" '$1 == "cell" && $2 == "macos" && $3 == "socat" && $4 == "hardened" { next } $1 == "scenario" && $3 == "macos/socat/hardened" { next } { print }'
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "a missing cell"
  assert_match 'macos/socat/hardened' "$RV_OUT" "names the skipped cell"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/b/receipt.tsv"
  rv_edit "$CASE_DIR/b/receipt.tsv" '$1 == "cell" && $2 == "linux" && $3 == "socat" && $4 == "standard" { $7 = "blocked" } { print }'
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "a blocked cell is never green"
  assert_match 'linux/socat/standard' "$RV_OUT" "names the blocked cell"
}

t_representative_matrix_needs_both_platforms() {
  rv_build baseline "$CASE_DIR/b" rep
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix representative
  assert_rc 0 "$RV_RC" "one linux and one macos cell: $RV_OUT"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "representative cells do not satisfy the full matrix"
  rv_edit "$CASE_DIR/b/receipt.tsv" '$1 == "cell" && $2 == "macos" { next } $1 == "scenario" && $3 ~ /^macos\// { next } { print }'
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix representative
  assert_nonzero "$RV_RC" "representative without macOS"
}

t_wrong_image_generation_fails() {
  rv_build baseline "$CASE_DIR/b"
  rv_edit "$CASE_DIR/b/receipt.tsv" '$1 == "scenario" && $2 == "BL-COLD" && $3 == "linux/haproxy/standard" { $7 = "pihole=sha256:old;unbound=sha256:old;proxy=sha256:old" } { print }'
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "scenario recorded against another image generation"
  assert_match 'image generation' "$RV_OUT" "names the image generation"
}

t_tampered_artifact_fails() {
  rv_build baseline "$CASE_DIR/b"
  printf 'edited\n' >>"$CASE_DIR/b/art/BL-STAGE.txt"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "artifact changed after the receipt"
  assert_match 'BL-STAGE' "$RV_OUT" "names the artifact"
}

t_tampered_aggregate_fails_even_when_rehashed() {
  local sha
  rv_build baseline "$CASE_DIR/b"
  sed 's/	1.0000	/	0.0000	/; s/	0.5000	/	0.0000	/' "$CASE_DIR/b/art/stats.tsv" >"$CASE_DIR/s" && cp "$CASE_DIR/s" "$CASE_DIR/b/art/stats.tsv"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "aggregate edited, hash stale"
  sha="$(rv_sha "$CASE_DIR/b/art/stats.tsv")"
  rv_edit "$CASE_DIR/b/receipt.tsv" "\$1 == \"aggregate\" { \$3 = \"$sha\" } { print }"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "aggregate edited and re-hashed still disagrees with its samples"
  assert_match 'recomput' "$RV_OUT" "names the recomputation"
}

t_dropped_cpu_platform_fails() {
  rv_build baseline "$CASE_DIR/b"
  rv_edit "$CASE_DIR/b/receipt.tsv" '$1 == "arch" && $2 == "tor-socat" { sub(/,?linux\/riscv64/, "", $4) } { print }'
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "receipt claims fewer platforms than source defines"
  assert_match 'tor-socat' "$RV_OUT" "names the image"
  rv_build baseline "$CASE_DIR/c"
  rv_edit "$CASE_DIR/c/receipt.tsv" '$1 == "arch" && $2 == "hardened-unbound" { next } { print }'
  rv "$CASE_DIR/c/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "missing CPU inventory for an image"
}

t_source_rows_required_for_every_repo() {
  local repo
  rv_build baseline "$CASE_DIR/ctl"
  rv "$CASE_DIR/ctl/receipt.tsv" --require-matrix all
  assert_rc 0 "$RV_RC" "control: the unmodified receipt verifies: $RV_OUT"
  for repo in $RV_REPOS; do
    rm -rf "$CASE_DIR/b"
    rv_build baseline "$CASE_DIR/b"
    rv_edit "$CASE_DIR/b/receipt.tsv" "\$1 == \"source\" && \$2 == \"$repo\" { next } { print }"
    rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
    assert_nonzero "$RV_RC" "receipt without source identity for $repo"
  done
}

t_dependency_link_is_verified() {
  rv_build transport "$CASE_DIR/t"
  rv "$CASE_DIR/t/receipt.tsv" --require-matrix all --require-dep baseline
  assert_rc 0 "$RV_RC" "transport linked to its baseline: $RV_OUT"
  printf 'x\n' >>"$CASE_DIR/t/dep-baseline/receipt.tsv"
  rv "$CASE_DIR/t/receipt.tsv" --require-matrix all --require-dep baseline
  assert_nonzero "$RV_RC" "linked baseline changed after linking"
  rm -rf "$CASE_DIR/t"
  rv_build transport "$CASE_DIR/t"
  rv_edit "$CASE_DIR/t/receipt.tsv" '$1 == "requires" { next } { print }'
  rv "$CASE_DIR/t/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "manifest-required dependency missing"
  assert_match 'baseline' "$RV_OUT" "names the missing dependency"
}

t_dependency_must_itself_verify() {
  rv_build transport "$CASE_DIR/t"
  rv_edit "$CASE_DIR/t/dep-baseline/receipt.tsv" '$1 == "scenario" && $2 == "BL-WARM" { next } { print }'
  rv_edit "$CASE_DIR/t/receipt.tsv" "\$1 == \"requires\" { \$4 = \"$(rv_sha "$CASE_DIR/t/dep-baseline/receipt.tsv")\" } { print }"
  rv "$CASE_DIR/t/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "a re-linked but incomplete baseline"
  assert_match 'BL-WARM' "$RV_OUT" "names the dependency's gap"
}

t_unknown_names_never_pass() {
  rv_build baseline "$CASE_DIR/b"
  cp "$CASE_DIR/b/receipt.tsv" "$CASE_DIR/orig.tsv"
  printf 'scenario\tBL-FUTURE\t-\tpass\tart/BL-STAGE.txt\t%s\t-\n' "$(rv_sha "$CASE_DIR/b/art/BL-STAGE.txt")" >>"$CASE_DIR/b/receipt.tsv"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "undeclared scenario id"
  assert_match 'BL-FUTURE' "$RV_OUT" "names the unknown scenario"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/b/receipt.tsv"
  printf 'bonus\tx\n' >>"$CASE_DIR/b/receipt.tsv"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_nonzero "$RV_RC" "unknown row type"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/b/receipt.tsv"
  rv_edit "$CASE_DIR/b/receipt.tsv" '$1 == "receipt" { $2 = "benchmark" } { print }'
  rv "$CASE_DIR/b/receipt.tsv"
  assert_nonzero "$RV_RC" "unknown receipt name"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/b/receipt.tsv"
  rv "$CASE_DIR/b/receipt.tsv" --require-widgets all
  assert_eq 2 "$RV_RC" "unknown requirement option"
}

t_schema_and_paths_are_strict() {
  rv_build baseline "$CASE_DIR/b"
  rv "$CASE_DIR/b/receipt.tsv"
  assert_rc 0 "$RV_RC" "control: the unmodified receipt verifies: $RV_OUT"
  cp "$CASE_DIR/b/receipt.tsv" "$CASE_DIR/orig.tsv"
  sed -i.bak '1s/receipt\/1/receipt\/2/' "$CASE_DIR/b/receipt.tsv"
  rv "$CASE_DIR/b/receipt.tsv"
  assert_nonzero "$RV_RC" "unknown schema version"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/b/receipt.tsv"
  rv_edit "$CASE_DIR/b/receipt.tsv" '$1 == "scenario" && $2 == "BL-STAGE" { $5 = "../outside.txt" } { print }'
  printf 'observed BL-STAGE\n' >"$CASE_DIR/outside.txt"
  rv "$CASE_DIR/b/receipt.tsv"
  assert_nonzero "$RV_RC" "artifact path escaping the receipt dir"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/b/receipt.tsv"
  rm "$CASE_DIR/b/art/BL-STAGE.txt" && ln -s "$CASE_DIR/outside.txt" "$CASE_DIR/b/art/BL-STAGE.txt"
  rv "$CASE_DIR/b/receipt.tsv"
  assert_nonzero "$RV_RC" "symlinked artifact"
}

t_entrypoints_requirement() {
  local e
  rv_build baseline "$CASE_DIR/b"
  rv "$CASE_DIR/b/receipt.tsv" --require-entrypoints all
  assert_nonzero "$RV_RC" "no entrypoint rows"
  for e in install-deb.sh install-deb-hardened.sh install-mac.sh install-mac-hardened.sh; do
    printf 'entrypoint\t%s\tpass\n' "$e" >>"$CASE_DIR/b/receipt.tsv"
  done
  rv "$CASE_DIR/b/receipt.tsv" --require-entrypoints all
  assert_rc 0 "$RV_RC" "all four entrypoints: $RV_OUT"
  rv_edit "$CASE_DIR/b/receipt.tsv" '$1 == "entrypoint" && $2 == "install-mac.sh" { $3 = "fail" } { print }'
  rv "$CASE_DIR/b/receipt.tsv" --require-entrypoints all
  assert_nonzero "$RV_RC" "a failed entrypoint"
}

t_receipt_manifests_are_consistent() {
  local m out
  for m in baseline transport controller installers qualification; do
    assert_file "$RV_MAN/$m.tsv" "receipt manifest $m"
  done
  out="$(bash "$RV" manifests 2>&1)"
  assert_rc 0 $? "manifest check: $out"
  assert_match 'qualification requires baseline,transport,controller,installers' "$out" "dependency chain reported"
}

t_runner_receipt_command_verifies_latest_receipt() {
  local root="$CASE_DIR/root" out rc
  out="$(NICE_DNS_TEST_ARTIFACTS="$root" bash "$NICE_DNS_ROOT/tests/run.sh" receipt baseline --require-matrix all 2>&1)"
  rc=$?
  assert_nonzero "$rc" "no baseline receipt yet"
  assert_ne 0 "$rc" "never green without a receipt"
  assert_match 'no .*receipt' "$out" "says there is no receipt"
  mkdir -p "$root/receipts/baseline"
  rv_build baseline "$root/receipts/baseline/20260922T000000Z-aaaaaaaa"
  out="$(NICE_DNS_TEST_ARTIFACTS="$root" bash "$NICE_DNS_ROOT/tests/run.sh" receipt baseline --require-matrix all 2>&1)"
  assert_rc 0 $? "runner verifies the latest baseline receipt: $out"
  out="$(NICE_DNS_TEST_ARTIFACTS="$root" bash "$NICE_DNS_ROOT/tests/run.sh" receipt transport --require-baseline baseline --require-proxies all 2>&1)"
  assert_nonzero $? "no transport receipt"
}

rv_rehash() {
  # rv_rehash RECEIPTDIR: recompute every scenario artifact hash, so a
  # tampered artifact is caught by its content, not by its sha256.
  local d="$1" tmp="$1/receipt.tmp"
  awk -F '\t' -v d="$d" 'BEGIN { OFS = "\t" }
    $1 == "scenario" { cmd = "sha256sum \"" d "/" $5 "\" 2>/dev/null || shasum -a 256 \"" d "/" $5 "\""; cmd | getline l; close(cmd); split(l, h, " "); $6 = h[1] }
    { print }' "$d/receipt.tsv" >"$tmp" && mv "$tmp" "$d/receipt.tsv"
}

t_stage_evidence_must_say_pass() {
  rv_build baseline "$CASE_DIR/b"
  printf 'git_head\t%s\ncollected=155 passed=100 failed=55\nresult=fail run_id=x\n' "$(git -C "$RV_SIB/nice-dns" rev-parse HEAD)" >"$CASE_DIR/b/art/BL-STAGE.txt"
  rv_rehash "$CASE_DIR/b"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_rc 1 "$RV_RC" "a failed stage run is not BL-STAGE evidence"
  assert_match 'BL-STAGE .*no line matching /\^result=pass' "$RV_OUT" "names the missing pass"
}

t_stage_evidence_must_name_the_source_commit() {
  rv_build baseline "$CASE_DIR/b"
  printf 'git_head\t%s\ncollected=1 passed=1 failed=0\nresult=pass run_id=x\n' 0123456789abcdef0123456789abcdef01234567 >"$CASE_DIR/b/art/BL-STAGE.txt"
  rv_rehash "$CASE_DIR/b"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_rc 1 "$RV_RC" "stage evidence from another commit"
  assert_match 'names git_head 0123456789abcdef' "$RV_OUT" "names the wrong head"
}

t_samples_from_another_cell_fail() {
  local f
  rv_build baseline "$CASE_DIR/b"
  f="$CASE_DIR/b/art/BL-COLD-linux-socat-standard.txt"
  cp "$CASE_DIR/b/art/BL-COLD-macos-socat-standard.txt" "$f"
  rv_rehash "$CASE_DIR/b"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_rc 1 "$RV_RC" "macOS samples filed under a linux cell"
  assert_match 'linux/socat/standard.*is macos/socat/standard' "$RV_OUT" "names the foreign cell"
}

t_too_few_samples_fail() {
  rv_build baseline "$CASE_DIR/b"
  head -n 101 "$CASE_DIR/b/art/BL-WARM-linux-haproxy-standard.txt" >"$CASE_DIR/w" && mv "$CASE_DIR/w" "$CASE_DIR/b/art/BL-WARM-linux-haproxy-standard.txt"
  rv_rehash "$CASE_DIR/b"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_rc 1 "$RV_RC" "99 warm samples is below the 1000 minimum"
  assert_match 'BL-WARM \(linux/haproxy/standard\) has 99 samples, fewer than the declared minimum 1000' "$RV_OUT" "names the shortfall"
}

t_empty_health_evidence_fails() {
  rv_build baseline "$CASE_DIR/b"
  : >"$CASE_DIR/b/art/BL-SEVERED-linux-haproxy-standard.txt"
  rv_rehash "$CASE_DIR/b"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_rc 1 "$RV_RC" "an empty severed observation"
  assert_match 'BL-SEVERED \(linux/haproxy/standard\).*no line matching /\^health' "$RV_OUT" "names the empty artifact"
}

t_samples_must_name_the_recorded_product() {
  rv_build baseline "$CASE_DIR/b"
  printf 'product\tnice-dns\t%s\n' 0123456789abcdef0123456789abcdef01234567 >>"$CASE_DIR/b/receipt.tsv"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_rc 1 "$RV_RC" "samples from another product revision"
  assert_match 'source_rev [0-9a-f]{40} is not the recorded revision 0123456789abcdef' "$RV_OUT" "names the revision mismatch"
  rv_build baseline "$CASE_DIR/c"
  printf 'product\tnice-dns\tmain\n' >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv" --require-matrix all
  assert_rc 1 "$RV_RC" "a product row must be a full commit id"
}

t_manifest_rules_must_name_declared_scenarios() {
  local m="$CASE_DIR/man"
  cp -R "$RV_MAN" "$m"
  printf 'minimum\tBL-NOPE\t5\n' >>"$m/baseline.tsv"
  NICE_DNS_TEST_MANIFESTS="$m" bash "$RV" manifests >"$CASE_DIR/out" 2>&1
  assert_rc 1 $? "a rule for an undeclared scenario"
  assert_match 'undeclared scenario BL-NOPE' "$(cat "$CASE_DIR/out")" "names it"
}

t_content_rules_keep_their_tabs() {
  # A content pattern is the literal rest of its manifest row, tabs included:
  # "running" elsewhere on a line is not a container whose state is running.
  rv_build baseline "$CASE_DIR/b"
  printf 'pi-hole\texited\t-\n# pi-hole was running before the fault\n' >"$CASE_DIR/b/art/BL-RESTORED-linux-haproxy-standard.txt"
  printf 'imagery\tnot an image row\n' >"$CASE_DIR/b/art/BL-CONFIG-linux-haproxy-standard.txt"
  rv_rehash "$CASE_DIR/b"
  rv "$CASE_DIR/b/receipt.tsv" --require-matrix all
  assert_rc 1 "$RV_RC" "substring matches are not field matches"
  assert_match 'BL-RESTORED \(linux/haproxy/standard\).*no line matching' "$RV_OUT" "a stopped container is not restored evidence"
  assert_match 'BL-CONFIG \(linux/haproxy/standard\).*no line matching' "$RV_OUT" "^image<TAB> keeps its tab"
}

t_platform_proxies_requirement() {
  # Sub-plan 3 close-out M3: --require-proxies all is satisfied by any
  # platform having each proxy; the controller's representative gate needs
  # each proxy on each platform (standard Pi-hole), so it asks for
  # --require-platform-proxies all.
  rv_build controller "$CASE_DIR/c"
  rv "$CASE_DIR/c/receipt.tsv" --require-platform-proxies all
  assert_rc 0 "$RV_RC" "every platform x proxy standard cell observed: $RV_OUT"
  rv_edit "$CASE_DIR/c/receipt.tsv" '$1 == "cell" && $2 == "macos" && $3 == "socat" { next } $1 == "scenario" && $3 ~ /^macos\/socat\// { next } { print }'
  rv "$CASE_DIR/c/receipt.tsv" --require-proxies all
  assert_rc 0 "$RV_RC" "linux/socat still satisfies the cross-platform --require-proxies: $RV_OUT"
  rv "$CASE_DIR/c/receipt.tsv" --require-platform-proxies all
  assert_nonzero "$RV_RC" "macOS without socat fails the per-platform requirement"
  assert_match 'macos/socat/standard' "$RV_OUT" "names the missing platform x proxy cell"
}

t_failed_cell_is_named_never_green() {
  # M3: the controller receipt records a cell that did not pass every
  # scenario as failed instead of dropping it; a failed cell never verifies.
  rv_build controller "$CASE_DIR/c"
  rv_edit "$CASE_DIR/c/receipt.tsv" '$1 == "cell" && $2 == "macos" && $3 == "socat" && $4 == "standard" { $7 = "failed" } $1 == "scenario" && $3 == "macos/socat/standard" { next } { print }'
  rv "$CASE_DIR/c/receipt.tsv"
  assert_nonzero "$RV_RC" "a failed cell never verifies"
  assert_match 'cell macos/socat/standard failed' "$RV_OUT" "says the cell failed"
}

t_limit_rows_are_checked_and_counted() {
  # M4: what a run did not prove is recorded as a limit with the sub-plan
  # that owns it, never implied by a passing scenario.
  rv_build controller "$CASE_DIR/c"
  printf 'limit\troute-apply\t-\tscope=sub-plan-4\tno deployment mounts the route directory; switch-route was not applied live\n' >>"$CASE_DIR/c/receipt.tsv"
  printf 'limit\tready-corroboration\tmacos/haproxy/standard\tscope=sub-plan-4\tthe Unbound image has no probe-route\n' >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv"
  assert_rc 0 "$RV_RC" "declared limits verify: $RV_OUT"
  assert_match 'limits=2' "$RV_OUT" "the summary counts the limits"
  cp "$CASE_DIR/c/receipt.tsv" "$CASE_DIR/orig.tsv"
  printf 'limit\troute-apply\t-\tsub-plan-4\tno scope key\n' >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv"
  assert_nonzero "$RV_RC" "a limit without scope=sub-plan-N fails"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/c/receipt.tsv"
  printf 'limit\tready-corroboration\tlinux/haproxy/nosuch\tscope=sub-plan-4\ttext\n' >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv"
  assert_nonzero "$RV_RC" "a limit naming a cell that is not observed fails"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/c/receipt.tsv"
  printf 'limit\troute-apply\t-\tscope=sub-plan-4\t\n' >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv"
  assert_nonzero "$RV_RC" "a limit without a reason fails"
}

t_reuse_rows_are_checked_and_counted() {
  # DEC-009 (user decision 2026-09-27): a gate may carry a cell that passed
  # in an earlier run instead of repeating it. The receipt names each such
  # cell, the run it came from and that run's nice-dns commit.
  local sha
  sha="$(git -C "$RV_SIB/nice-dns" rev-parse HEAD)"
  rv_build controller "$CASE_DIR/c"
  printf 'reuse\tlinux/haproxy/standard\t20260926T190619Z-bcd92da5\t%s\n' "$sha" >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv"
  assert_rc 0 "$RV_RC" "a reused observed cell verifies: $RV_OUT"
  assert_match 'reused=1' "$RV_OUT" "the summary counts reused cells"
  cp "$CASE_DIR/c/receipt.tsv" "$CASE_DIR/orig.tsv"
  printf 'reuse\tlinux/haproxy/standard\t20260926T210648Z-e72d9762\t%s\n' "$sha" >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv"
  assert_nonzero "$RV_RC" "a cell reused twice fails"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/c/receipt.tsv"
  printf 'reuse\tlinux/haproxy/nosuch\t20260926T190619Z-bcd92da5\t%s\n' "$sha" >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv"
  assert_nonzero "$RV_RC" "reusing a cell that is not observed fails"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/c/receipt.tsv"
  printf 'reuse\tmacos/haproxy/standard\trun-test-controller\t%s\n' "$sha" >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv"
  assert_nonzero "$RV_RC" "a reuse must name another, well-formed run"
  cp "$CASE_DIR/orig.tsv" "$CASE_DIR/c/receipt.tsv"
  printf 'reuse\tmacos/haproxy/standard\t20260926T190619Z-bcd92da5\tabc\n' >>"$CASE_DIR/c/receipt.tsv"
  rv "$CASE_DIR/c/receipt.tsv"
  assert_nonzero "$RV_RC" "a reuse names the full commit it ran"
}

t_reused_cell_is_found_only_when_it_passed_everything() {
  # cs_reuse_cell (tests/live/controller-lib.sh) picks an earlier run's cell
  # only when that cell passed all six scenarios; a partly passed or failed
  # cell is never carried, and a cell of this run is never replaced.
  local r1="$CASE_DIR/runs/20260101T000000Z-aaaaaaaa" r2="$CASE_DIR/runs/20260102T000000Z-bbbbbbbb" c k out
  for r in "$r1" "$r2"; do mkdir -p "$r/controller-active"; done
  mkdir -p "$r1/controller-active/linux-haproxy-standard" "$r2/controller-active/linux-haproxy-standard" "$r2/controller-active/macos-socat-standard"
  printf 'cell\tlinux/haproxy/standard\nnice_dns\t%s\n' "$(printf 'a%.0s' $(seq 40))" >"$r1/controller-active/linux-haproxy-standard/cell.tsv"
  cp "$r1/controller-active/linux-haproxy-standard/cell.tsv" "$r2/controller-active/linux-haproxy-standard/cell.tsv"
  printf 'cell\tmacos/haproxy/standard\n' >"$r2/controller-active/macos-socat-standard/cell.tsv"
  for k in CT-PROBES CT-PRIMARY-ONLY CT-RECOVERY-ACK CT-CACHE-VS-UPSTREAM CT-RUNTIME-WEDGE CT-BRIDGES; do
    printf '%s\tpass\tx.txt\n' "$k" >>"$r1/controller-active/linux-haproxy-standard/observations.tsv"
  done
  head -n 4 "$r1/controller-active/linux-haproxy-standard/observations.tsv" >"$r2/controller-active/linux-haproxy-standard/observations.tsv"
  cp "$r1/controller-active/linux-haproxy-standard/observations.tsv" "$r2/controller-active/macos-socat-standard/observations.tsv"
  ( . "$NICE_DNS_ROOT/tests/live/controller-lib.sh"
    NICE_DNS_CELL_REUSE_RUNS="$r2 $r1"
    assert_eq "$r1/controller-active/linux-haproxy-standard" "$(cs_reuse_cell linux/haproxy/standard)" "the run whose cell passed all six is used, not a later partial one"
    assert_eq "" "$(cs_reuse_cell macos/socat/standard)" "a cell whose recorded key differs from its directory is refused"
    assert_eq "" "$(cs_reuse_cell linux/socat/standard)" "a cell no run passed is not reused"
    NICE_DNS_CELL_REUSE_RUNS="relative/run"
    out="$(cs_reuse_cell linux/haproxy/standard 2>&1)"; assert_nonzero "$?" "a reuse run must be an absolute directory: $out"
  ) || exit 1
}
