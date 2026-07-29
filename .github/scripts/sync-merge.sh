#!/usr/bin/env bash
# Merge SOURCE_REF into TARGET_BRANCH, replaying recorded rerere resolutions and
# falling back to a pull request when conflicts remain.
#
#   sync-merge.sh <source_ref> <target_branch> <pr_head_branch> <output_key>
#
# <pr_head_branch> is the branch a fallback PR is opened from. When it differs
# from <source_ref> (because the source lives in another repository) the source
# is pushed there first so GitHub has something to open the PR against.
#
# Writes "<output_key>_status" (clean|rerere|conflict) to $GITHUB_OUTPUT, and on
# the conflict path "<output_key>_pr_url" via sync-conflict-pr.sh.

set -euo pipefail

source_ref="$1"
target_branch="$2"
pr_head="$3"
output_key="$4"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git checkout "${target_branch}"

# rerere must be configured before the merge so resolutions can be replayed.
git config rerere.enabled true
git config rerere.autoUpdate true
if [ -f bin/rerere-cache ]; then
  bash bin/rerere-cache import
else
  echo "bin/rerere-cache not present on ${target_branch}; merging without recorded resolutions"
fi

unresolved=""
if git merge --no-edit "${source_ref}"; then
  status=clean
elif [ -z "$(git ls-files --unmerged)" ]; then
  # rerere resolved and staged every conflicted path; the merge only needs a commit.
  git commit --no-edit
  status=rerere
else
  unresolved="$(git diff --name-only --diff-filter=U)"
  git merge --abort
  status=conflict
fi

echo "${output_key}_status=${status}" >> "${GITHUB_OUTPUT}"

if [ "${status}" != conflict ]; then
  if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/${target_branch}")" ]; then
    git push origin "${target_branch}"
  else
    echo "${target_branch} already up to date; nothing to push"
  fi
  exit 0
fi

echo "::warning::Conflicts remain in ${target_branch} after rerere; opening a pull request."

# Stage the source commits on a branch in this repository so the pull request is
# entirely local; the upstream remote is only ever read from.
if [ "${source_ref}" != "${pr_head}" ]; then
  git push --force origin "${source_ref}:refs/heads/${pr_head}"
fi

BASE_BRANCH="${target_branch}" \
HEAD_BRANCH="${pr_head}" \
UNRESOLVED="${unresolved}" \
OUTPUT_KEY="${output_key}" \
  "${script_dir}/sync-conflict-pr.sh"
