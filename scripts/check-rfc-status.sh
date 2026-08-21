#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rfcs_dir="${repo_root}/docs/rfcs"

if [[ -z "${NO_COLOR:-}" && ( -t 1 || -n "${FORCE_COLOR:-}" ) ]]; then
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

read_metadata() {
    local rfc="$1"

    awk '
      BEGIN {
        id = ""
        title = ""
        status = ""
        line_nr = 0
        in_front_matter = 0
      }
      {
        line_nr++

        if (line_nr == 1 && $0 == "---") {
          in_front_matter = 1
          next
        }

        if (in_front_matter) {
          if ($0 == "---") {
            in_front_matter = 0
            next
          }

          key = tolower($0)
          value = $0
          sub(/^[^:]+:[[:space:]]*/, "", value)

          if (id == "" && key ~ /^rfc:[[:space:]]*/) {
            id = value
          } else if (title == "" && key ~ /^title:[[:space:]]*/) {
            title = value
          } else if (status == "" && key ~ /^status:[[:space:]]*/) {
            status = value
          }
        }
      }
      END { printf "%s\t%s\t%s\n", id, title, status }
    ' "${rfc}"
}

read_checklist_counts() {
    local rfc="$1"

    awk '
      BEGIN { complete = 0; total = 0 }
      /^([[:space:]]*[-+*]|[[:space:]]*[0-9]+\.)[[:space:]]+\[[Xx ]\]/ {
        total++
        if ($0 ~ /\[[Xx]\]/) {
          complete++
        }
      }
      END { printf "%d %d\n", complete, total }
    ' "${rfc}"
}

printf "%s%-4s  %-10s  %-9s  %s%s\n" "${color_bold}" "RFC" "Status" "Progress" "Title" "${color_reset}"
printf "%s%-4s  %-10s  %-9s  %s%s\n" "${color_dim}" "----" "------" "--------" "------------------------------" "${color_reset}"

failures=0
found=0
declare -A seen_ids=()

shopt -s nullglob
rfcs=("${rfcs_dir}"/*.md)
shopt -u nullglob

if [[ "${#rfcs[@]}" -eq 0 ]]; then
    printf "%sno RFC files found%s in %s\n" "${color_red}" "${color_reset}" "${rfcs_dir}" >&2
    exit 1
fi

mapfile -t rfcs < <(printf '%s\n' "${rfcs[@]}" | sort -V)

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
    metadata="$(read_metadata "${rfc}")"
    id="${metadata%%$'\t'*}"
    remainder="${metadata#*$'\t'}"
    title="${remainder%%$'\t'*}"
    status="${remainder#*$'\t'}"

    if [[ -z "${id}" ]]; then
        id="(missing)"
        failures=$((failures + 1))
    elif [[ "${id}" != "${filename_id}" ]]; then
        printf "  %sRFC number mismatch%s in %s: frontmatter has %s\n" "${color_red}" "${color_reset}" "${filename}" "${id}" >&2
        failures=$((failures + 1))
    elif [[ -n "${seen_ids[${id}]:-}" ]]; then
        printf "  %sduplicate RFC number%s in %s and %s\n" "${color_red}" "${color_reset}" "${seen_ids[${id}]}" "${filename}" >&2
        failures=$((failures + 1))
    else
        seen_ids["${id}"]="${filename}"
    fi

    if [[ -z "${title}" ]]; then
        title="(missing title)"
        failures=$((failures + 1))
    fi

    if [[ -z "${status}" ]]; then
        status="(missing)"
        failures=$((failures + 1))
    fi

    counts="$(read_checklist_counts "${rfc}")"
    complete_count="${counts%% *}"
    total_count="${counts##* }"

    status_field="$(printf "%-10s" "${status}")"
    progress_field="$(printf "%-9s" "${complete_count}/${total_count}")"
    status_text="$(colorize_status "${status}" "${status_field}")"
    progress_text="$(colorize_progress "${complete_count}" "${total_count}" "${progress_field}")"

    printf "%-4s  %s  %s  %s\n" "${filename_id}" "${status_text}" "${progress_text}" "${title}"

    case "${status}" in
    Draft | Accepted | Active | Paused | Done | Rejected | Superseded) ;;
    *)
        printf "  %sinvalid status%s in %s: %s\n" "${color_red}" "${color_reset}" "${filename}" "${status}" >&2
        failures=$((failures + 1))
        ;;
    esac

    if [[ "${total_count}" -eq 0 ]]; then
        printf "  %sacceptance checklist is missing%s in %s\n" "${color_red}" "${color_reset}" "${filename}" >&2
        failures=$((failures + 1))
    elif [[ "${complete_count}" -eq "${total_count}" && "${status}" != "Done" && "${status}" != "Rejected" && "${status}" != "Superseded" ]]; then
        printf "  %sexpected Done, Rejected, or Superseded%s in %s: all checklist items are done\n" "${color_red}" "${color_reset}" "${filename}" >&2
        failures=$((failures + 1))
    elif [[ "${complete_count}" -lt "${total_count}" && "${status}" == "Done" ]]; then
        printf "  %sexpected an unfinished status%s in %s: checklist still has open items\n" "${color_red}" "${color_reset}" "${filename}" >&2
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
