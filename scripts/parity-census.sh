#!/usr/bin/env bash
set -uo pipefail

status=0
executed=0
seen_ids=$'\n'
seen_commands=$'\n'
expected_required_rows=55
expected_unique_evidence_commands=19
expected_case_id_checksum=9aea595abb39b20dc3f484101f7313c4ab4e62a11b369093134b39a487969436
expected_mapping_checksum=890943290da3792c36ceb7a057749fe1ffcf466165581fe4802a3ae93470dad7
expected_taxonomy_emitted=71
expected_taxonomy_declared_not_emitted=7
expected_taxonomy_triples=145

if command -v shasum >/dev/null 2>&1; then
  sha256_tool=shasum
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_tool=sha256sum
elif command -v openssl >/dev/null 2>&1; then
  sha256_tool=openssl
else
  printf 'CENSUS_SHA256_TOOL_MISSING requires shasum, sha256sum, or openssl\n' >&2
  exit 1
fi

sha256_stdin() {
  case "$sha256_tool" in
    shasum) shasum -a 256 | awk '{print $1}' ;;
    sha256sum) sha256sum | awk '{print $1}' ;;
    openssl) openssl dgst -sha256 | awk '{print $NF}' ;;
  esac
}

run_test() {
  evidence_id=$1
  shift
  printf 'CENSUS_COMMAND'
  printf ' %q' "$@"
  printf '\n'
  output=$("$@" </dev/null 2>&1)
  result=$?
  printf '%s\n' "$output"
  marker_count=$(grep -Fxc "CENSUS_PROBE ${evidence_id}" <<<"$output")
  if (( result != 0 )) ||
      [[ $(grep -Fxc 'All 1 tests passed.' <<<"$output") -ne 1 ]] ||
      [[ "$marker_count" != 1 ]]; then
    printf 'CENSUS_TEST_FAILED %s\n' "$evidence_id" >&2
    status=1
  else
    executed=$((executed + 1))
  fi
}

printf 'CENSUS_COMMAND zig run --dep parity_requirements -Mroot=src/parity_census.zig -Mparity_requirements=testdata/protocol_parity_requirements.zig\n'
census_output=$(zig run \
  --dep parity_requirements \
  -Mroot=src/parity_census.zig \
  -Mparity_requirements=testdata/protocol_parity_requirements.zig 2>&1)
census_result=$?
printf '%s\n' "$census_output"
if (( census_result != 0 )); then
  exit "$census_result"
fi

for marker in CENSUS_MISSING CENSUS_FABRICATED CENSUS_INTEGRITY_ERRORS; do
  if [[ $(grep -Fxc "${marker} 0" <<<"$census_output") -ne 1 ]]; then
    status=1
  fi
done
total=$(sed -n 's/^CENSUS_TOTAL //p' <<<"$census_output")
row_probe_references=$(
  sed -n 's/^CENSUS_ROW_PROBE_REFERENCES //p' <<<"$census_output"
)
expected=$(sed -n 's/^CENSUS_UNIQUE_EVIDENCE_COMMANDS //p' <<<"$census_output")
taxonomy_emitted=$(sed -n 's/^CENSUS_TAXONOMY_EMITTED //p' <<<"$census_output")
taxonomy_declared_not_emitted=$(
  sed -n 's/^CENSUS_TAXONOMY_DECLARED_NOT_EMITTED //p' <<<"$census_output"
)
taxonomy_triples=$(sed -n 's/^CENSUS_TAXONOMY_TRIPLES //p' <<<"$census_output")
boundary_total=$(awk '$1 == "CENSUS_COUNT" { sum += $3 } END { print sum + 0 }' <<<"$census_output")
case_id_checksum=$(
  tail -n +2 testdata/protocol-parity-requirements.tsv |
    cut -f1 |
    LC_ALL=C sort |
    sha256_stdin
)
mapping_checksum=$(
  grep $'^CENSUS_MAPPING\t' <<<"$census_output" |
    cut -f2- |
    sha256_stdin
)
printf 'CENSUS_CASE_ID_SHA256 %s\n' "$case_id_checksum"
printf 'CENSUS_MAPPING_SHA256 %s\n' "$mapping_checksum"
if [[ "$total" != "$expected_required_rows" || "$boundary_total" != "$expected_required_rows" ]]; then
  printf 'CENSUS_REQUIRED_ROW_ANCHOR_CHANGED expected=%d reported=%s boundaries=%s\n' \
    "$expected_required_rows" "${total:-missing}" "$boundary_total" >&2
  status=1
fi
if [[ "$row_probe_references" != "$expected_required_rows" ]]; then
  printf 'CENSUS_ROW_PROBE_REFERENCE_ANCHOR_CHANGED expected=%d reported=%s\n' \
    "$expected_required_rows" "${row_probe_references:-missing}" >&2
  status=1
fi
if [[ "$case_id_checksum" != "$expected_case_id_checksum" ]]; then
  printf 'CENSUS_CASE_ID_ANCHOR_CHANGED expected=%s reported=%s\n' \
    "$expected_case_id_checksum" "${case_id_checksum:-missing}" >&2
  status=1
fi
if [[ "$mapping_checksum" != "$expected_mapping_checksum" ]]; then
  printf 'CENSUS_MAPPING_ANCHOR_CHANGED expected=%s reported=%s\n' \
    "$expected_mapping_checksum" "${mapping_checksum:-missing}" >&2
  status=1
fi
if [[ "$taxonomy_emitted" != "$expected_taxonomy_emitted" ||
      "$taxonomy_declared_not_emitted" != "$expected_taxonomy_declared_not_emitted" ||
      "$taxonomy_triples" != "$expected_taxonomy_triples" ]]; then
  printf 'CENSUS_TAXONOMY_ANCHOR_CHANGED expected=%d/%d/%d reported=%s/%s/%s\n' \
    "$expected_taxonomy_emitted" "$expected_taxonomy_declared_not_emitted" \
    "$expected_taxonomy_triples" "${taxonomy_emitted:-missing}" \
    "${taxonomy_declared_not_emitted:-missing}" "${taxonomy_triples:-missing}" >&2
  status=1
fi
if [[ "$expected" != "$expected_unique_evidence_commands" ]]; then
  printf 'CENSUS_EVIDENCE_COMMAND_ANCHOR_CHANGED expected=%d reported=%s\n' \
    "$expected_unique_evidence_commands" "${expected:-missing}" >&2
  status=1
fi

while IFS=$'\t' read -r marker evidence_id source_file evidence_kind test_filter package_root; do
  [[ "$marker" == "CENSUS_TEST" ]] || continue
  command_key="${source_file}"$'\t'"${test_filter}"
  if [[ -z "$evidence_id" || -z "$source_file" || -z "$evidence_kind" || -z "$test_filter" ]] ||
      grep -Fqx "$evidence_id" <<<"$seen_ids" ||
      grep -Fqx "$command_key" <<<"$seen_commands"; then
    status=1
    continue
  fi
  seen_ids+="${evidence_id}"$'\n'
  seen_commands+="${command_key}"$'\n'
  if [[ -n "$package_root" ]]; then
    run_test "$evidence_id" zig test \
      --dep copilot_sdk \
      "-Mroot=${source_file}" \
      "-Mcopilot_sdk=${package_root}" \
      --test-filter "$test_filter"
  else
    run_test "$evidence_id" zig test "$source_file" --test-filter "$test_filter"
  fi
done <<<"$census_output"

if [[ "$executed" != "$expected" ]]; then
  status=1
fi
printf 'CENSUS_EXECUTED_TESTS %d/%s\n' "$executed" "${expected:-0}"

exit "$status"
