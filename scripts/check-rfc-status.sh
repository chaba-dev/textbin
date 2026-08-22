#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rfcs_dir="${RFCS_DIR:-${repo_root}/docs/rfcs}"

if [[ -z "${NO_COLOR:-}" && (-t 1 || -n "${FORCE_COLOR:-}") ]]; then
	color_reset=$'\033[0m'
	color_bold=$'\033[1m'
	color_red=$'\033[31m'
	color_green=$'\033[32m'
	color_yellow=$'\033[33m'
	color_blue=$'\033[34m'
	color_magenta=$'\033[35m'
	color_dim=$'\033[2m'
else
	color_reset=""
	color_bold=""
	color_red=""
	color_green=""
	color_yellow=""
	color_blue=""
	color_magenta=""
	color_dim=""
fi

if [[ ! -d "${rfcs_dir}" ]]; then
	printf "%sRFC directory not found:%s %s\n" "${color_red}" "${color_reset}" "${rfcs_dir}" >&2
	exit 1
fi

colorize_status() {
	local status="$1"
	local padded="$2"

	case "${status}" in
	Draft) printf "%s%s%s" "${color_blue}" "${padded}" "${color_reset}" ;;
	Accepted | Active) printf "%s%s%s" "${color_yellow}" "${padded}" "${color_reset}" ;;
	Paused) printf "%s%s%s" "${color_magenta}" "${padded}" "${color_reset}" ;;
	Done) printf "%s%s%s" "${color_green}" "${padded}" "${color_reset}" ;;
	Rejected | Superseded) printf "%s%s%s" "${color_dim}" "${padded}" "${color_reset}" ;;
	*) printf "%s%s%s" "${color_red}" "${padded}" "${color_reset}" ;;
	esac
}

colorize_progress() {
	local complete="$1"
	local total="$2"
	local padded="$3"

	if [[ "${complete}" -eq "${total}" ]]; then
		printf "%s%s%s" "${color_green}" "${padded}" "${color_reset}"
	elif [[ "${complete}" -eq 0 ]]; then
		printf "%s%s%s" "${color_dim}" "${padded}" "${color_reset}"
	else
		printf "%s%s%s" "${color_yellow}" "${padded}" "${color_reset}"
	fi
}

read_rfc() {
	local rfc="$1"
	local filename="$2"

	awk -v filename="${filename}" '
      function problem(message) {
        printf "  %s: %s\n", filename, message > "/dev/stderr"
        errors++
      }

      BEGIN {
        id = ""
        title = ""
        status = ""
        in_frontmatter = 0
        frontmatter_closed = 0
        acceptance_sections = 0
        in_acceptance = 0
        complete = 0
        total = 0
        errors = 0
      }

      {
        if (NR == 1) {
          if ($0 == "---") {
            in_frontmatter = 1
          } else {
            problem("frontmatter must start on the first line")
          }
          next
        }

        if (in_frontmatter && $0 == "---") {
          frontmatter_closed = 1
          in_frontmatter = 0
          next
        }

        if (in_frontmatter) {
          key = tolower($0)
          value = $0
          sub(/^[^:]+:[[:space:]]*/, "", value)

          if (index(value, "\t") > 0) {
            problem("frontmatter values must not contain tabs")
            gsub(/\t/, " ", value)
          }

          if (key ~ /^rfc:[[:space:]]*/) {
            id_count++
            if (id_count == 1) id = value
          } else if (key ~ /^title:[[:space:]]*/) {
            title_count++
            if (title_count == 1) title = value
          } else if (key ~ /^status:[[:space:]]*/) {
            status_count++
            if (status_count == 1) status = value
          }
          next
        }

        if ($0 ~ /^## Acceptance criteria[[:space:]]*$/) {
          acceptance_sections++
          in_acceptance = 1
          next
        }

        if ($0 ~ /^##[[:space:]]/) {
          in_acceptance = 0
          next
        }

        if (in_acceptance && $0 ~ /^([[:space:]]*[-+*]|[[:space:]]*[0-9]+\.)[[:space:]]+\[[Xx ]\]/) {
          total++
          if ($0 ~ /\[[Xx]\]/) complete++
        }
      }

      END {
        if (!frontmatter_closed) problem("frontmatter is not closed")

        if (id_count != 1 || id == "") {
          problem("frontmatter must contain exactly one non-empty rfc value")
        }

        if (title_count != 1 || title == "") {
          problem("frontmatter must contain exactly one non-empty title value")
        }

        if (status_count != 1 || status == "") {
          problem("frontmatter must contain exactly one non-empty status value")
        }

        if (acceptance_sections != 1) {
          problem("document must contain exactly one Acceptance criteria section")
        } else if (total == 0) {
          problem("Acceptance criteria must contain at least one checklist item")
        }

        printf "%s\t%s\t%s\t%d\t%d\t%d\n", id, title, status, complete, total, errors
      }
    ' "${rfc}"
}

printf "%s%-4s  %-10s  %-9s  %s%s\n" "${color_bold}" "RFC" "Status" "Progress" "Title" "${color_reset}"
printf "%s%-4s  %-10s  %-9s  %s%s\n" "${color_dim}" "----" "------" "--------" "------------------------------" "${color_reset}"

failures=0
found=0
seen_ids=""

shopt -s nullglob
rfcs=("${rfcs_dir}"/*.md)
shopt -u nullglob

if [[ "${#rfcs[@]}" -eq 0 ]]; then
	printf "%sno RFC files found%s in %s\n" "${color_red}" "${color_reset}" "${rfcs_dir}" >&2
	exit 1
fi

for rfc in "${rfcs[@]}"; do
	filename="$(basename "${rfc}")"

	if [[ "${filename}" == "README.md" ]]; then
		continue
	fi

	found=1

	if [[ ! "${filename}" =~ ^([0-9]{4})-[a-z0-9]+(-[a-z0-9]+)*\.md$ ]]; then
		printf "%sinvalid RFC filename%s: %s\n" "${color_red}" "${color_reset}" "${filename}" >&2
		failures=$((failures + 1))
		continue
	fi

	filename_id="${BASH_REMATCH[1]}"
	parsed="$(read_rfc "${rfc}" "${filename}")"
	id="${parsed%%$'\t'*}"
	remainder="${parsed#*$'\t'}"
	title="${remainder%%$'\t'*}"
	remainder="${remainder#*$'\t'}"
	status="${remainder%%$'\t'*}"
	remainder="${remainder#*$'\t'}"
	complete_count="${remainder%%$'\t'*}"
	remainder="${remainder#*$'\t'}"
	total_count="${remainder%%$'\t'*}"
	parser_errors="${remainder#*$'\t'}"
	failures=$((failures + parser_errors))

	if [[ -n "${id}" && "${id}" != "${filename_id}" ]]; then
		printf "  %sRFC number mismatch%s in %s: frontmatter has %s\n" "${color_red}" "${color_reset}" "${filename}" "${id}" >&2
		failures=$((failures + 1))
	fi

	if [[ -n "${id}" ]]; then
		case "${seen_ids}" in
		*"|${id}|"*)
			printf "  %sduplicate RFC number%s in %s: %s\n" "${color_red}" "${color_reset}" "${filename}" "${id}" >&2
			failures=$((failures + 1))
			;;
		*) seen_ids="${seen_ids}|${id}|" ;;
		esac
	fi

	status_field="$(printf "%-10s" "${status:-\(missing\)}")"
	progress_field="$(printf "%-9s" "${complete_count}/${total_count}")"
	status_text="$(colorize_status "${status}" "${status_field}")"
	progress_text="$(colorize_progress "${complete_count}" "${total_count}" "${progress_field}")"

	printf "%-4s  %s  %s  %s\n" "${filename_id}" "${status_text}" "${progress_text}" "${title:-\(missing title\)}"

	case "${status}" in
	Draft | Accepted | Active | Paused | Done | Rejected | Superseded) ;;
	"") ;;
	*)
		printf "  %sinvalid status%s in %s: %s\n" "${color_red}" "${color_reset}" "${filename}" "${status}" >&2
		failures=$((failures + 1))
		;;
	esac

	if [[ "${total_count}" -gt 0 && "${complete_count}" -eq "${total_count}" && "${status}" != "Done" && "${status}" != "Rejected" && "${status}" != "Superseded" ]]; then
		printf "  %sexpected Done, Rejected, or Superseded%s in %s: all acceptance criteria are done\n" "${color_red}" "${color_reset}" "${filename}" >&2
		failures=$((failures + 1))
	elif [[ "${complete_count}" -lt "${total_count}" && "${status}" == "Done" ]]; then
		printf "  %sexpected an unfinished status%s in %s: acceptance criteria remain open\n" "${color_red}" "${color_reset}" "${filename}" >&2
		failures=$((failures + 1))
	fi
done

if [[ "${found}" -eq 0 ]]; then
	printf "%sno RFC files found%s in %s\n" "${color_red}" "${color_reset}" "${rfcs_dir}" >&2
	exit 1
fi

if [[ "${failures}" -gt 0 ]]; then
	echo
	printf "%sRFC status check failed%s with %s issue(s).\n" "${color_red}" "${color_reset}" "${failures}" >&2
	exit 1
fi

echo
printf "%sRFC status check passed.%s\n" "${color_green}" "${color_reset}"
