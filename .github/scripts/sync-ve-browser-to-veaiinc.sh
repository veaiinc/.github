#!/usr/bin/env bash
set -euo pipefail

SOURCE_ORG="${SOURCE_ORG:-Ve-Browser}"
TARGET_ORG="${TARGET_ORG:-veaiinc}"
REPO_LIMIT="${REPO_LIMIT:-1000}"
DISABLE_TARGET_ACTIONS="${DISABLE_TARGET_ACTIONS:-true}"
WORK_ROOT="${RUNNER_TEMP:-/tmp}/ve-browser-to-veaiinc-sync"

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN is required. Use a token that can read ${SOURCE_ORG} and create/write repos in ${TARGET_ORG}." >&2
  exit 1
fi

mkdir -p "${WORK_ROOT}"
repos_file="${WORK_ROOT}/repositories.txt"

gh auth setup-git --hostname github.com >/dev/null

if [[ -n "${SYNC_REPOSITORIES:-}" ]]; then
  printf '%s\n' "${SYNC_REPOSITORIES}" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sort -u > "${repos_file}"
else
  gh repo list "${SOURCE_ORG}" \
    --limit "${REPO_LIMIT}" \
    --json name,isArchived \
    --jq '.[] | select(.name != ".github") | select(.isArchived | not) | .name' \
    | sort -u > "${repos_file}"
fi

if [[ ! -s "${repos_file}" ]]; then
  echo "No repositories selected for sync."
  exit 0
fi

while IFS= read -r repo; do
  [[ -z "${repo}" ]] && continue

  echo "::group::${SOURCE_ORG}/${repo} -> ${TARGET_ORG}/${repo}"

  source_json="$(gh repo view "${SOURCE_ORG}/${repo}" --json defaultBranchRef,description,visibility)"
  default_branch="$(jq -r '.defaultBranchRef.name // ""' <<< "${source_json}")"
  description="$(jq -r '.description // ""' <<< "${source_json}")"

  if gh repo view "${TARGET_ORG}/${repo}" >/dev/null 2>&1; then
    echo "Target repository exists."
  else
    if [[ -n "${description}" ]]; then
      gh repo create "${TARGET_ORG}/${repo}" --private --description "Mirror of ${SOURCE_ORG}/${repo}: ${description}" >/dev/null
    else
      gh repo create "${TARGET_ORG}/${repo}" --private --description "Mirror of ${SOURCE_ORG}/${repo}" >/dev/null
    fi
    echo "Created private target repository."
  fi

  if [[ "${DISABLE_TARGET_ACTIONS}" == "true" ]]; then
    gh api -X PUT "repos/${TARGET_ORG}/${repo}/actions/permissions" -F enabled=false >/dev/null || {
      echo "Warning: could not disable Actions on ${TARGET_ORG}/${repo}." >&2
    }
  fi

  protected_branches="$(
    gh api "repos/${TARGET_ORG}/${repo}/branches?per_page=100" --paginate --jq '.[] | select(.protected) | .name' 2>/dev/null || true
  )"
  while IFS= read -r protected_branch; do
    [[ -z "${protected_branch}" ]] && continue
    encoded_branch="$(jq -rn --arg value "${protected_branch}" '$value | @uri')"
    gh api -X DELETE "repos/${TARGET_ORG}/${repo}/branches/${encoded_branch}/protection" >/dev/null || {
      echo "Warning: could not remove branch protection for ${TARGET_ORG}/${repo}:${protected_branch}." >&2
    }
  done <<< "${protected_branches}"

  repo_dir="${WORK_ROOT}/${repo}.git"
  if [[ -d "${repo_dir}" ]]; then
    echo "Removing stale local mirror ${repo_dir}."
    chmod -R u+w "${repo_dir}" || true
    rm -rf "${repo_dir}"
  fi

  git clone --bare "https://github.com/${SOURCE_ORG}/${repo}.git" "${repo_dir}" >/dev/null

  if git -C "${repo_dir}" show-ref --heads --quiet; then
    git -C "${repo_dir}" push "https://github.com/${TARGET_ORG}/${repo}.git" '+refs/heads/*:refs/heads/*'
  else
    echo "Source has no branches."
  fi

  if git -C "${repo_dir}" show-ref --tags --quiet; then
    git -C "${repo_dir}" push "https://github.com/${TARGET_ORG}/${repo}.git" '+refs/tags/*:refs/tags/*'
  else
    echo "Source has no tags."
  fi

  if [[ -n "${default_branch}" ]]; then
    gh repo edit "${TARGET_ORG}/${repo}" --default-branch "${default_branch}" >/dev/null || {
      echo "Warning: could not set default branch ${default_branch} on ${TARGET_ORG}/${repo}." >&2
    }
  fi

  echo "Synced ${repo}."
  echo "::endgroup::"
done < "${repos_file}"
