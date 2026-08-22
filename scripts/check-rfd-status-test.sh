#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/scripts/check-rfd-status.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/textbin-rfd-check.XXXXXX")"
rfd_root="${test_root}/rfd"
output="${test_root}/output"

trap 'rm -rf "${test_root}"' EXIT

reset_fixtures() {
	rm -rf "${rfd_root}"
	mkdir -p "${rfd_root}"
	printf '# Test RFDs\n' >"${rfd_root}/README.md"
}

run_success() {
	if ! NO_COLOR=1 RFD_DIR="${rfd_root}" bash "${checker}" >"${output}" 2>&1; then
		cat "${output}" >&2
		printf 'expected RFD checker to pass\n' >&2
		exit 1
	fi
}

run_failure() {
	local expected="$1"

	if NO_COLOR=1 RFD_DIR="${rfd_root}" bash "${checker}" >"${output}" 2>&1; then
		cat "${output}" >&2
		printf 'expected RFD checker to fail with: %s\n' "${expected}" >&2
		exit 1
	fi

	if ! grep -Fq "${expected}" "${output}"; then
		cat "${output}" >&2
		printf 'RFD checker failure did not include: %s\n' "${expected}" >&2
		exit 1
	fi
}

write_valid_rfd() {
	local state="$1"
	local discussion="$2"

	mkdir -p "${rfd_root}/0001"
	cat >"${rfd_root}/0001/README.adoc" <<EOF
:authors: Example Author <author@example.com>
:state: ${state}
:discussion: ${discussion}
:labels: software, process

= RFD 1 Valid RFD
EOF
}

reset_fixtures
write_valid_rfd discussion https://example.com/pull/1
run_success

reset_fixtures
write_valid_rfd prediscussion ""
run_success

reset_fixtures
write_valid_rfd draft ""
run_failure "invalid state: draft"

reset_fixtures
write_valid_rfd discussion ""
run_failure "state discussion requires a discussion URL"

reset_fixtures
write_valid_rfd prediscussion ""
sed -i.bak '1a\
:authors: Another Author <another@example.com>
' "${rfd_root}/0001/README.adoc"
rm "${rfd_root}/0001/README.adoc.bak"
run_failure "exactly one non-empty authors attribute"

reset_fixtures
write_valid_rfd prediscussion ""
sed -i.bak 's/= RFD 1 /= RFD 2 /' "${rfd_root}/0001/README.adoc"
rm "${rfd_root}/0001/README.adoc.bak"
run_failure "does not match directory number 1"

reset_fixtures
mkdir -p "${rfd_root}/1"
printf '= RFD 1 Invalid directory\n' >"${rfd_root}/1/README.adoc"
run_failure "invalid RFD entry"

printf 'RFD checker tests passed.\n'
