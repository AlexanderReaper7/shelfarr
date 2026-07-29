#!/usr/bin/env bash
# Render the Sync Upstream job summary and fail the run if any merge needed a
# pull request, so an incomplete sync is visible without digging into logs.

set -euo pipefail

describe() {
  local status="$1" source="$2" target="$3" pr="$4"
  case "${status}" in
    clean)
      echo "- \`${source}\` -> \`${target}\`: merged cleanly."
      ;;
    rerere)
      echo "- \`${source}\` -> \`${target}\`: conflicts resolved automatically from the recorded rerere cache. **Check CI on \`${target}\`** — a replayed resolution can be clean but wrong."
      ;;
    conflict)
      echo "- \`${source}\` -> \`${target}\`: **needs manual resolution** — ${pr}"
      ;;
    *)
      echo "- \`${source}\` -> \`${target}\`: did not run."
      ;;
  esac
}

{
  echo "### Sync Upstream"
  echo ""
  echo "Source: \`${UPSTREAM_REPO}@${UPSTREAM_BRANCH}\`"
  echo ""
  describe "${MIRROR_STATUS:-}" "upstream/${UPSTREAM_BRANCH}" "${TARGET_BRANCH}" "${MIRROR_PR:-}"
  describe "${PERSONAL_STATUS:-}" "${TARGET_BRANCH}" "${PERSONAL_BRANCH}" "${PERSONAL_PR:-}"
} >> "${GITHUB_STEP_SUMMARY}"

if [ "${MIRROR_STATUS:-}" = conflict ] || [ "${PERSONAL_STATUS:-}" = conflict ]; then
  echo "::error::Sync finished with unresolved conflicts; see the pull request linked in the summary."
  exit 1
fi
