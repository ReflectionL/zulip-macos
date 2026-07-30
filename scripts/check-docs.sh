#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

required_files=(AGENTS.md PLAN.md TRACKER.md README.md LICENSE)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "missing required project document: $required_file" >&2
    exit 1
  fi
done

for project_document in AGENTS.md PLAN.md TRACKER.md; do
  for linked_document in AGENTS.md PLAN.md TRACKER.md; do
    if ! rg -q "$linked_document" "$project_document"; then
      echo "$project_document does not reference $linked_document" >&2
      exit 1
    fi
  done
done

in_progress_count="$(
  rg -c '^\| [A-Z]+-[0-9]+ .* \| in_progress \|$' PLAN.md || true
)"

if [[ "$in_progress_count" -gt 1 ]]; then
  echo "PLAN.md contains more than one in-progress step" >&2
  exit 1
fi

current_step="$(
  sed -n 's/^- Current step: `\([^`]*\)`.*/\1/p' TRACKER.md
)"

if [[ -n "$current_step" ]] &&
  ! rg -q "^\| ${current_step} .* \| in_progress \|$" PLAN.md; then
  echo "TRACKER.md current step is not in progress in PLAN.md: $current_step" >&2
  exit 1
fi

echo "project documentation checks passed"
