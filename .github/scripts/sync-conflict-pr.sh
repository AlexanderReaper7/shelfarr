#!/usr/bin/env bash
# Open (or update) a pull request when Sync Upstream cannot merge the target
# branch into the personal branch automatically.
#
# Expects: GH_TOKEN, TARGET_BRANCH, PERSONAL_BRANCH, UNRESOLVED (newline-separated
# paths), plus the usual GITHUB_* variables. Writes `url` to $GITHUB_OUTPUT.

set -euo pipefail

run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
conflict_list="$(printf '%s\n' "${UNRESOLVED}" | sed '/^$/d; s/^/- `/; s/$/`/')"

existing="$(gh pr list --base "${PERSONAL_BRANCH}" --head "${TARGET_BRANCH}" \
  --state open --json number --jq '.[0].number // empty')"

if [ -n "${existing}" ]; then
  gh pr comment "${existing}" --body "$(cat <<EOF
Sync run [\`${GITHUB_RUN_ID}\`](${run_url}) still hits conflicts in:

${conflict_list}
EOF
)"
  echo "url=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${existing}" >> "${GITHUB_OUTPUT}"
  exit 0
fi

url="$(gh pr create --base "${PERSONAL_BRANCH}" --head "${TARGET_BRANCH}" \
  --title "Sync ${TARGET_BRANCH} into ${PERSONAL_BRANCH}" \
  --body "$(cat <<EOF
Automated sync could not merge \`${TARGET_BRANCH}\` into \`${PERSONAL_BRANCH}\`.
Conflicts remain in:

${conflict_list}

Resolve them with GitHub's web editor, or locally:

\`\`\`bash
git fetch origin
git checkout ${PERSONAL_BRANCH}
bin/rerere-cache enable
git merge ${TARGET_BRANCH}
# resolve the conflicts, then:
git add -A && git merge --continue
bin/rerere-cache export
git add .rerere-cache && git commit -m 'chore: record conflict resolution'
git push
\`\`\`

Exporting the rerere cache lets the next sync replay this resolution on its own.

Triggered by run [\`${GITHUB_RUN_ID}\`](${run_url}).
EOF
)")"

echo "url=${url}" >> "${GITHUB_OUTPUT}"
