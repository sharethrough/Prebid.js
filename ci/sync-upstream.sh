#!/usr/bin/env bash
# sync-upstream.sh
#
# Merges prebid/Prebid.js master into github-sharethrough-prebidjs so the
# long-lived branch keeps tracking upstream.  Upstream is the source of truth;
# the branch's own commits (CI files under ci/, .gitlab-ci.yml, the equativ
# adapter customisations) are preserved by the merge — a merge only ADDS the
# upstream changes, it never drops files that exist only on this branch.
#
# Runs on a schedule and can also be triggered manually from the GitLab UI
# (Pipelines → Run pipeline, then play the job).  See .gitlab-ci.yml.
#
# On a merge conflict the job aborts WITHOUT pushing and exits non-zero, so a
# human resolves it locally.  The push uses `-o ci.skip` so the resulting merge
# commit does NOT trigger the ship-to-upstream pipeline (there is no MR behind
# a sync merge, so ship would only skip anyway — this just avoids the noise).
#
# Required env vars (GitLab CI):
#   GITLAB_PUSH_TOKEN  – token with write_repository on this project, allowed
#                        to push to the protected branch (project/group access
#                        token with Maintainer role, or a PAT).  Masked.
#   CI_SERVER_HOST     – provided by GitLab
#   CI_PROJECT_PATH    – provided by GitLab
#
# Optional env vars:
#   UPSTREAM_REPO_URL  – defaults to https://github.com/prebid/Prebid.js.git
#   UPSTREAM_BRANCH    – defaults to master
#   TARGET_BRANCH      – defaults to github-sharethrough-prebidjs

set -euo pipefail

UPSTREAM_REPO_URL="${UPSTREAM_REPO_URL:-https://github.com/prebid/Prebid.js.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
TARGET_BRANCH="${TARGET_BRANCH:-github-sharethrough-prebidjs}"

: "${GITLAB_PUSH_TOKEN:?GITLAB_PUSH_TOKEN must be set (write_repository token allowed to push to ${TARGET_BRANCH})}"

echo "==> Syncing ${UPSTREAM_REPO_URL}@${UPSTREAM_BRANCH} into ${TARGET_BRANCH}"

# ── Identity (required to create a merge commit) ────────────────────────────
git config --global user.email "ci-bot@sharethrough.com"
git config --global user.name  "Sharethrough CI"

# ── Remotes ─────────────────────────────────────────────────────────────────
git remote add upstream "${UPSTREAM_REPO_URL}" 2>/dev/null \
  || git remote set-url upstream "${UPSTREAM_REPO_URL}"

# `origin` in CI authenticates with CI_JOB_TOKEN, which cannot push to a
# protected branch — use a dedicated remote carrying the push token.
PUSH_URL="https://oauth2:${GITLAB_PUSH_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
git remote add gitlab-push "${PUSH_URL}" 2>/dev/null \
  || git remote set-url gitlab-push "${PUSH_URL}"

# ── Fetch both sides ────────────────────────────────────────────────────────
echo "==> Fetching upstream and target"
git fetch upstream "${UPSTREAM_BRANCH}"
git fetch origin   "${TARGET_BRANCH}"

# Start from origin's tip of the target branch (the CI checkout may be detached).
git checkout -B "${TARGET_BRANCH}" "origin/${TARGET_BRANCH}"

# ── Already up to date? ─────────────────────────────────────────────────────
BEHIND=$(git rev-list --count "HEAD..upstream/${UPSTREAM_BRANCH}")
echo "    ${BEHIND} upstream commit(s) to merge"
if [ "${BEHIND}" -eq 0 ]; then
  echo "==> Already up to date — nothing to do"
  exit 0
fi

# ── Merge (preserves branch-only files; fails on conflict) ──────────────────
echo "==> Merging upstream/${UPSTREAM_BRANCH}"
if git merge --no-ff -m "ci: sync upstream/${UPSTREAM_BRANCH} into ${TARGET_BRANCH}" \
     "upstream/${UPSTREAM_BRANCH}"; then
  echo "    Merge clean"
else
  echo "ERROR: merge conflict — aborting without pushing. Resolve manually:" >&2
  git --no-pager diff --name-only --diff-filter=U >&2 || true
  git merge --abort 2>/dev/null || true
  exit 1
fi

# ── Push (skip CI so this merge doesn't trigger ship-to-upstream) ───────────
echo "==> Pushing ${TARGET_BRANCH}"
git push -o ci.skip gitlab-push "HEAD:refs/heads/${TARGET_BRANCH}"

echo "==> Done — ${TARGET_BRANCH} now tracks upstream/${UPSTREAM_BRANCH}"
