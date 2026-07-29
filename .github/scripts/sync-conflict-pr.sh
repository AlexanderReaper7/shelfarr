#!/usr/bin/env bash
# Open (or update) a pull request when Sync Upstream cannot merge a branch
# automatically.
#
# Expects: GH_TOKEN, BASE_BRANCH, HEAD_BRANCH, UNRESOLVED (newline-separated
# paths), OUTPUT_KEY, plus the usual GITHUB_* variables.
# Writes "<OUTPUT_KEY>_pr_url" to $GITHUB_OUTPUT.

set -euo pipefail

run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
conflict_list="$(printf '%s\n' "${UNRESOLVED}" | sed '/^$/d; s/^/- `/; s/$/`/')"

existing="$(gh pr list --base "${BASE_BRANCH}" --head "${HEAD_BRANCH}" \
  --state open --json number --jq '.[0].number // empty')"

if [ -n "${existing}" ]; then
  gh pr comment "${existing}" --body "$(cat <<EOF
Sync run [\`${GITHUB_RUN_ID}\`](${run_url}) still hits conflicts in:

${conflict_list}
EOF
)"
  echo "${OUTPUT_KEY}_pr_url=${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/pull/${existing}" >> "${GITHUB_OUTPUT}"
  exit 0
fi

if ! url="$(gh pr create --base "${BASE_BRANCH}" --head "${HEAD_BRANCH}" \
  --title "Sync ${HEAD_BRANCH} into ${BASE_BRANCH}" \
  --body "$(cat <<EOF
Automated sync could not merge \`${HEAD_BRANCH}\` into \`${BASE_BRANCH}\`.
Conflicts remain in:

${conflict_list}

Resolve them with GitHub's web editor, or locally:

\`\`\`bash
git fetch origin
git checkout ${BASE_BRANCH}
bin/rerere-cache enable
git merge origin/${HEAD_BRANCH}
# resolve the conflicts, then:
git add -A && git merge --continue
bin/rerere-cache export
git add .rerere-cache && git commit -m 'chore: record conflict resolution'
git push
\`\`\`

Exporting the rerere cache lets the next sync replay this resolution on its own.

Triggered by run [\`${GITHUB_RUN_ID}\`](${run_url}).
EOF
)")"; then
  case "${HEAD_BRANCH}" in
    *:*)
      echo "::error::Could not open a pull request from ${HEAD_BRANCH}. GITHUB_TOKEN cannot create a pull request whose head branch lives in another repository. Add a personal access token with the 'repo' and 'workflow' scopes as the SYNC_TOKEN secret."
      ;;
    *)
      echo "::error::Could not open a pull request from ${HEAD_BRANCH} into ${BASE_BRANCH}."
      ;;
  esac
  echo "${OUTPUT_KEY}_pr_url=(could not be created -- see the log)" >> "${GITHUB_OUTPUT}"
  exit 1
fi

echo "${OUTPUT_KEY}_pr_url=${url}" >> "${GITHUB_OUTPUT}"
