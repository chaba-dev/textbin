#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/scripts/check-rfc-status.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/textbin-rfc-check.XXXXXX")"
rfcs_dir="${test_root}/rfcs"
output="${test_root}/output"

trap 'rm -rf "${test_root}"' EXIT

reset_fixtures() {
	rm -rf "${rfcs_dir}"
	mkdir -p "${rfcs_dir}"
	printf '# Test RFCs\n' >"${rfcs_dir}/README.md"
}

run_success() {
	if ! NO_COLOR=1 RFCS_DIR="${rfcs_dir}" bash "${checker}" >"${output}" 2>&1; then
		cat "${output}" >&2
		printf 'expected RFC checker to pass\n' >&2
		exit 1
	fi
}

run_failure() {
	local expected="$1"

	if NO_COLOR=1 RFCS_DIR="${rfcs_dir}" bash "${checker}" >"${output}" 2>&1; then
		cat "${output}" >&2
		printf 'expected RFC checker to fail with: %s\n' "${expected}" >&2
		exit 1
	fi

	if ! grep -Fq "${expected}" "${output}"; then
		cat "${output}" >&2
		printf 'RFC checker failure did not include: %s\n' "${expected}" >&2
		exit 1
	fi
}

reset_fixtures
cat >"${rfcs_dir}/0001-valid.md" <<'EOF'
---
rfc: 0001
title: Valid RFC
status: Draft
---

## Acceptance criteria

- [ ] It works.
EOF
run_success

reset_fixtures
cat >"${rfcs_dir}/0001-unclosed.md" <<'EOF'
---
rfc: 0001
title: Unclosed RFC
status: Draft

## Acceptance criteria

- [ ] It works.
EOF
run_failure "frontmatter is not closed"

reset_fixtures
cat >"${rfcs_dir}/0001-duplicate-metadata.md" <<'EOF'
---
rfc: 0001
rfc: 0001
title: Duplicate metadata
status: Draft
---

## Acceptance criteria

- [ ] It works.
EOF
run_failure "exactly one non-empty rfc value"

reset_fixtures
cat >"${rfcs_dir}/0001-no-acceptance.md" <<'EOF'
---
rfc: 0001
title: No acceptance section
status: Draft
---

## Work items

- [ ] This unrelated task must not count.
EOF
run_failure "exactly one Acceptance criteria section"

reset_fixtures
cat >"${rfcs_dir}/0001-complete.md" <<'EOF'
---
rfc: 0001
title: Complete acceptance criteria
status: Active
---

## Work items

- [ ] This unrelated task must not affect progress.

## Acceptance criteria

- [x] It works.
EOF
run_failure "all acceptance criteria are done"

reset_fixtures
for slug in first second; do
	cat >"${rfcs_dir}/0001-${slug}.md" <<'EOF'
---
rfc: 0001
title: Duplicate number
status: Draft
---

## Acceptance criteria

- [ ] It works.
EOF
done
run_failure "duplicate RFC number"

printf 'RFC checker tests passed.\n'
