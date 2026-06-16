#!/usr/bin/env bash
# ship-to-upstream.sh
#
# Triggered on every push to github-sharethrough-prebidjs (i.e. after an MR is
# merged).  Finds the MR that produced the merge commit, and — unless the MR
# carries the "no-upstream" label — pushes the source branch to
# sharethrough/Prebid.js.
#
# Required env vars (supplied by GitLab CI):
#   CI_COMMIT_SHA        – merge commit SHA
#   CI_PROJECT_ID        – numeric GitLab project ID
#   CI_JOB_TOKEN         – short-lived token for same-project API reads
#   GH_APP_ID            – GitHub App ID (masked CI variable)
#   GH_APP_PRIVATE_KEY   – GitHub App private key PEM (masked CI variable)
#
# Optional env vars:
#   GITLAB_API_URL       – defaults to https://gitlab.com/api/v4
#   GITHUB_API_URL       – defaults to https://api.github.com
#   FORK_REPO            – sharethrough fork, defaults to sharethrough/Prebid.js

set -euo pipefail

GITLAB_API_URL="${GITLAB_API_URL:-https://gitlab.com/api/v4}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
FORK_REPO="${FORK_REPO:-sharethrough/Prebid.js}"
FORK_ORG="${FORK_REPO%%/*}"

# ── 1. Find the MR that produced this merge commit ──────────────────────────

echo "==> Looking up MR for commit ${CI_COMMIT_SHA}"

MR_JSON=$(curl -sf \
  --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
  "${GITLAB_API_URL}/projects/${CI_PROJECT_ID}/merge_requests?state=merged&target_branch=github-sharethrough-prebidjs&order_by=updated_at&sort=desc&per_page=20" \
  | jq -r --arg sha "${CI_COMMIT_SHA}" \
      '[.[] | select(.merge_commit_sha == $sha)] | first')

if [ -z "${MR_JSON}" ] || [ "${MR_JSON}" = "null" ]; then
  echo "No merged MR found for commit ${CI_COMMIT_SHA} — skipping (direct push?)"
  exit 0
fi

SOURCE_BRANCH=$(echo "${MR_JSON}" | jq -r '.source_branch')
MR_IID=$(echo "${MR_JSON}"       | jq -r '.iid')
MR_TITLE=$(echo "${MR_JSON}"     | jq -r '.title')
LABELS=$(echo "${MR_JSON}"       | jq -r '[.labels[]] | join(",")')

echo "    MR !${MR_IID}: ${MR_TITLE}"
echo "    Source branch : ${SOURCE_BRANCH}"
echo "    Labels        : ${LABELS:-<none>}"

# ── 2. Bail out if the MR carries the no-upstream label ─────────────────────

if echo ",${LABELS}," | grep -q ",no-upstream,"; then
  echo "==> Label 'no-upstream' detected — skipping upstream ship"
  exit 0
fi

# ── 3. Mint a GitHub App installation token ─────────────────────────────────

echo "==> Minting GitHub App installation token"

# Write the PEM key to a temp file; handle both real newlines and literal \n.
TMPKEY=$(mktemp /tmp/gh-app-key.XXXXXX)
trap 'rm -f "${TMPKEY}"' EXIT

printf '%s' "${GH_APP_PRIVATE_KEY}" > "${TMPKEY}"
# If the PEM header isn't on its own line the key was stored with literal \n —
# replace them with real newlines.
if ! grep -q '^-----' "${TMPKEY}"; then
  printf '%s' "${GH_APP_PRIVATE_KEY}" | sed 's/\\n/\n/g' > "${TMPKEY}"
fi
chmod 600 "${TMPKEY}"

# Build a RS256 JWT: base64url(header).base64url(payload)
_b64url() { base64 -w 0 | tr '+/' '-_' | tr -d '='; }

NOW=$(date +%s)
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}'                                       | _b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((NOW - 60))" "$((NOW + 540))" \
            "${GH_APP_ID}"                                                           | _b64url)

SIGNING_INPUT="${HEADER}.${PAYLOAD}"

SIGNATURE=$(printf '%s' "${SIGNING_INPUT}" \
  | openssl dgst -sha256 -sign "${TMPKEY}" -binary \
  | _b64url)

JWT="${SIGNING_INPUT}.${SIGNATURE}"

# Resolve the installation that belongs to the fork org.
INSTALLATION_ID=$(curl -sf \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/app/installations" \
  | jq -r --arg org "${FORK_ORG}" \
      '.[] | select(.account.login == $org) | .id')

if [ -z "${INSTALLATION_ID}" ]; then
  echo "ERROR: No GitHub App installation found for org '${FORK_ORG}'" >&2
  exit 1
fi

GH_TOKEN=$(curl -sf -X POST \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/app/installations/${INSTALLATION_ID}/access_tokens" \
  | jq -r '.token')

echo "    Installation ID : ${INSTALLATION_ID}"
echo "    Token obtained  : yes"

# ── 4. Push the merged branch to sharethrough/Prebid.js ─────────────────────

echo "==> Pushing ${SOURCE_BRANCH} to ${FORK_REPO}"

git remote add github-fork \
  "https://x-access-token:${GH_TOKEN}@github.com/${FORK_REPO}.git" 2>/dev/null \
  || git remote set-url github-fork \
       "https://x-access-token:${GH_TOKEN}@github.com/${FORK_REPO}.git"

git push github-fork \
  "HEAD:refs/heads/${SOURCE_BRANCH}" \
  --force-with-lease

echo "    Branch pushed to ${FORK_REPO}/${SOURCE_BRANCH}"

# ── 5. Open a PR on sharethrough/Prebid.js ──────────────────────────────────

echo "==> Opening PR on ${FORK_REPO}"

DEFAULT_BRANCH=$(curl -sf \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/repos/${FORK_REPO}" \
  | jq -r '.default_branch')

PR_URL=$(curl -sf -X POST \
  -H "Authorization: Bearer ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API_URL}/repos/${FORK_REPO}/pulls" \
  --data "$(jq -n \
    --arg title "${MR_TITLE}" \
    --arg head  "${SOURCE_BRANCH}" \
    --arg base  "${DEFAULT_BRANCH}" \
    --arg body  "GitLab MR !${MR_IID}: ${MR_TITLE}" \
    '{title: $title, head: $head, base: $base, body: $body}')" \
  | jq -r '.html_url')

if [ -z "${PR_URL}" ] || [ "${PR_URL}" = "null" ]; then
  echo "    WARNING: PR may already exist or could not be created"
else
  echo "    PR opened: ${PR_URL}"
fi

echo "==> Done"
