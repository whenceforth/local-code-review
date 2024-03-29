#!/usr/bin/env bash

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${DIR}/.codereview.config.default"
override_config="${DIR}/.codereview.config"
if [ -r "$override_config" ]; then
  # https://www.shellcheck.net/wiki/SC1090
  # shellcheck source=/dev/null
  echo "using override config: ${override_config}"
  source "${override_config}"
else
  echo "using default config only"
fi

function debug {
  if [ "${CR_LOG_DEBUG}" = "1" ] || [ "${CR_LOG_INFO}" = "1" ]; then
    echo "CR.DEBUG ${1}"
  fi
}

function info {
  if [ "${CR_LOG_INFO}" = "1" ]; then
    echo "CR.INFO  ${1}"
  fi
}

function output {
  echo "CR       ${1}"
}

function fail_with_msg {
  echo "Exiting due to failure: ${1}"
  exit 1
}

# If env var CR_CONFIRM is non-empty, asks for confirmation and exits on answer not y or Y.
function confirm {
  if [[ -z "${CR_CONFIRM}" ]]; then
    return
  fi

  read -r -p 'Do you want to continue? y/n: ' shall_we

  case "${shall_we}" in
  "y" | "Y")
    echo "continuing..."
    ;;
  *)
    echo "exiting on choice of '${shall_we}'"
    exit 1
    ;;
  esac
}

# Sets environment variables OWNER and PROJECT to values parsed from `git config --get remote.origin.url`
# It requires that upstream be referred to as origin.
function get_repo_owner_and_name {

  declare origin_url=$(git config --get remote.origin.url)

  # The following line transforms both https://github.com/whenceforth/exercise-code-review.git and
  # git@github.com:whenceforth/exercise-code-review.git into the same format so that we can then
  # extract OWNER and PROJECT with only 1 awk program for each item.
  declare common_format=$(echo ${origin_url} | sed 's/https:/https/' | sed 's/@/\/\//' | tr ':' '/')

  OWNER=$(echo "${common_format}" | awk -F'/' '{print $4}')
  PROJECT=$(echo "${common_format}" | awk -F'/' '{print $5}' | awk -F'.' '{print $1}')

  debug "get_repo_owner_and_name: OWNER=${OWNER}, PROJECT=${PROJECT}"
}

# Set environment variable PROJECT_BASE_DIR_NAME to the name of the top level directory
# holding the repo.
#
# For example, in ~/code/github-repos/client-co/b-the-app (or in
# any of its children), it sets the variable to 'b-the-app'
function get_project_base_dir_name {
  rev_parse=$(git rev-parse --show-toplevel)
  PROJECT_BASE_DIR_NAME=$(basename "$rev_parse")
}

# https://unix.stackexchange.com/questions/366581/bash-associative-array-printing
function print_array {
  declare -n __p="$1"
  for k in "${!__p[@]}"; do
    printf "%s=%s\n" "$k" "${__p[$k]}"
  done
}

# arguments:
# 1: The branch for which we want to get info
# 2: An associative array name reference to put the info in
# Side effects:
# Sets the keys tracking, remote, and remote_url in the provided associative array
function get_branch_info {
  declare the_branch="${1}"
  declare -n my_assoc="${2}"
  my_assoc["branch"]="${the_branch}"

  declare tracking=$(git config branch.${the_branch}.merge)

  if [ -z "${tracking}" ]; then
    debug "get_branch_info: git config returned nothing. Fetching origin ${the_branch}"
    git fetch origin "${the_branch}"
    tracking=$(git config branch.${the_branch}.merge)
    debug "get_branch_info: After fetching origin ${the_branch}, tracking=${tracking}"
  fi;

  my_assoc["tracking"]=${tracking}

  declare remote=$(git config branch.${the_branch}.remote)
  my_assoc["remote"]="${remote}"

  declare remote_url=$(git remote get-url origin)
  my_assoc["remote_url"]="${remote_url}"

  debug "get_branch_info: the_branch=${the_branch}, tracking=${tracking}, remote=${remote}, remote_url=${remote_url}"
}

# Stores current git branch name in MY_CURRENT_BRANCH
function get_current_branch {
  MY_CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
}

function get_branch_data_dir_and_file {

  local scratch_dir="$1" || "${HOME}/.tmp/codereview"
  get_repo_owner_and_name
  get_project_base_dir_name
  get_current_branch

  CR_DATA_DIR="${scratch_dir}/${PROJECT}"

  # Using PROJECT_BASE_DIR_NAME as the filename allows multiple simultaneous reviews of different local copies
  # of the same repo. Rarely needed but helpful to have when it is needed.
  CR_DATA_FILE="${CR_DATA_DIR}/${PROJECT_BASE_DIR_NAME}.txt"
  info "get_branch_data_dir_and_file: PROJECT=${PROJECT}, CR_DATA_DIR=${CR_DATA_DIR}, CR_DATA_FILE=${CR_DATA_FILE}"
  debug "get_branch_data_dir_and_file: CR_DATA_FILE=${CR_DATA_FILE}"
}

# Reads the following:
# 1. git project name (aka 'the-app' or 'vault')
# 2. current local repo dir basename, such as 'the-app' or 'b-the-app'
# 3. current branch name, such as my_branch
#
# It then writes current branch name into a file named for project/local-repo-dir
# under scratch_dir, which should be passed as parameter to the function.
function store_current_branch_name {

  local scratch_dir="$1" || "${HOME}/.tmp/codereview"

  # Obtain MY_CURRENT_BRANCH, CR_DATA_DIR, and CR_DATA_FILE
  get_branch_data_dir_and_file "${scratch_dir}"

  debug "store_current_branch_name: CR_DATA_FILE=${CR_DATA_FILE}"

  mkdir -p "${CR_DATA_DIR}"

  echo "${MY_CURRENT_BRANCH}" >"${CR_DATA_FILE}"
  debug "remembered current branch (${MY_CURRENT_BRANCH}) in ${CR_DATA_FILE}"
}

# Reads the following:
# 1. git project name (aka 'foo')
# 2. current local repo dir basename, such as 'foo' or 'b-foo'
#
# It then looks for a file named for project/local-repo-dir under $scratch_dir,
# which should be passed as a parameter to the function,
# and cats it s contents into environment var STORED_BRANCH_NAME.
# If the data file is not found, it defaults to 'master'
function read_stored_branch_name {

  local scratch_dir="$1" || "${HOME}/.tmp/codereview"

  # Obtain MY_CURRENT_BRANCH, CR_DATA_DIR, and CR_DATA_FILE
  get_branch_data_dir_and_file "${scratch_dir}"

  debug "read_stored_branch_name: CR_DATA_FILE=${CR_DATA_FILE}"

  # TODO: Better fallback for STORED_BRANCH_NAME, e.g. specify a DEFAULT_RESTORE_BRANCH in config.
  STORED_BRANCH_NAME=$(cat "${CR_DATA_FILE}" 2>/dev/null || echo 'master')

  info "STORED_BRANCH_NAME=${STORED_BRANCH_NAME}"
}

function delete_stored_branch_name {
  local scratch_dir="$1" || "${HOME}/.tmp/codereview"

  # Obtain MY_CURRENT_BRANCH, CR_DATA_DIR, and CR_DATA_FILE
  get_branch_data_dir_and_file "${scratch_dir}"

  rm "${CR_DATA_FILE}" || output "failed to delete ${CR_DATA_FILE}"
}

# Checks out FEATURE_BRANCH for review and does a preview merge of that branch into a copy
# of TARGET_BRANCH. (The copy is TEMP_BRANCH.)
# Args:
# 1. FEATURE_BRANCH (required) contains the code to be reviewed
# 2. TARGET_BRANCH (optional) the branch into which FEATURE_BRANCH will be merged;
# If not specified, uses DEFAULT_TARGET_BRANCH from .codereview.config.default with override by .codereview.config)
# 3. TEMP_BRANCH (optional) the name of the temporary branch (copy of TARGET_BRANCH) that will be created for
# the merge preview. Defaults to DEFAULT_TEMP_BRANCH from .codereview.config.default with override by .codereview.config)
function review_branch {
  FEATURE_BRANCH=$1
  TARGET_BRANCH=$2
  TEMP_BRANCH=$3

  [ -z "${1:-}" ] && {
    fail_with_msg "review_branch: must specify branch to review (FEATURE_BRANCH)"
  }

  [ -z "${2:-}" ] && TARGET_BRANCH=${DEFAULT_TARGET_BRANCH}
  [ -z "${3:-}" ] && TEMP_BRANCH=${DEFAULT_TEMP_BRANCH}

  debug "review_branch: FEATURE_BRANCH=${FEATURE_BRANCH}, TARGET_BRANCH=${TARGET_BRANCH}, TEMP_BRANCH=${TEMP_BRANCH}"

  # review-finished will use this to restore the current branch
  # SCRATCH_DIR is read from config so we disable this warning https://www.shellcheck.net/wiki/SC2153
  # shellcheck disable=SC2153
  store_current_branch_name "${SCRATCH_DIR}"

  # Save any outstanding changes
  git stash save
  declare -A target_branch_info
  get_branch_info "${TARGET_BRANCH}" target_branch_info

  # Get latest code, including branch to be reviewed

  if [ -n "${target_branch_info[remote]}" ]; then
    git fetch origin "${TARGET_BRANCH}" || fail_with_msg "git fetch origin for TARGET_BRANCH=${TARGET_BRANCH}"
  fi

  git checkout "${TARGET_BRANCH}" || fail_with_msg "git checkout for TARGET_BRANCH=${TARGET_BRANCH}"

  if [ -n "${target_branch_info[remote]}" ]; then
    git pull origin "${TARGET_BRANCH}" || fail_with_msg "git pull origin for TARGET_BRANCH=${TARGET_BRANCH}"
  fi

  declare -A feature_branch_info
  get_branch_info "${FEATURE_BRANCH}" feature_branch_info

  # Get a local copy of the branch to be reviewed
  if [ -n "${feature_branch_info[remote]}" ]; then
    git fetch origin "${FEATURE_BRANCH}" || fail_with_msg "git fetch origin ${FEATURE_BRANCH}"
  fi

  git checkout "${FEATURE_BRANCH}" || fail_with_msg "git checkout ${FEATURE_BRANCH}"

  if [ -n "${feature_branch_info[remote]}" ]; then
    # Make sure it is up to date - e.g. updates after earlier feedback.
    git pull origin "${FEATURE_BRANCH}" || fail_with_msg "git pull origin ${FEATURE_BRANCH}"
  fi

  # Now make a copy of TARGET_BRANCH to preview the merge with.
  git checkout "${TARGET_BRANCH}"
  # Delete any older review branch
  git branch -D --quiet "${TEMP_BRANCH}" 2>/dev/null || info "no previous work branch found (using ${TEMP_BRANCH})"
  # Create a new work branch
  git checkout -b "${TEMP_BRANCH}" || fail_with_msg "git checkout -b ${TEMP_BRANCH}"
  # Apply changes without committing.  View diffs in IDE
  git merge --no-commit --no-ff -- "${FEATURE_BRANCH}" || fail_with_msg "git merge --no-commit --no-ff -- ${FEATURE_BRANCH}"

  output
  output "git status: "
  output
  git st

  output
  output
  output "FEATURE_BRANCH=${FEATURE_BRANCH}, TARGET_BRANCH=${TARGET_BRANCH}, TEMP_BRANCH=${TEMP_BRANCH}"
  output
  output "When finished with review, you can to discard the preview merge by running:"
  output "             ${DIR}/review-finished"
  output

}

# Uses the Github API to pull branch names for a PR and calls review-branch with them.
# Requires a github oauth token be stored in this directory in a file called .ghub_oauth_pr_review
# Input: PR number
function review_pr {
  PR_NUM=$1

  get_repo_owner_and_name
  info "OWNER=${OWNER}, PROJECT=${PROJECT}"

  # read oauth token from file
  ghub_oauth=$(<"${DIR}/.ghub_oauth_pr_review")

  api_result=$(curl -H "Accept: application/vnd.github.v3+json" -H "Authorization: token ${ghub_oauth}" \
    "https://api.github.com/repos/${OWNER}/${PROJECT}/pulls/$PR_NUM)")

  # jq -r emits strings without wrapping quotes
  FROM=$(echo "${api_result}" | jq -r '.head.ref')

  if [ -z "$FROM" ] || [ "$FROM" = "null" ]; then
    fail_with_msg "github api call failed: api_result=${api_result}"
  fi

  TO=$(echo "${api_result}" | jq -r '.base.ref')
  info "TO=${TO}"

  review_branch "${FROM}" "${TO}" "${DEFAULT_TEMP_BRANCH}"
}

function review_pr_gh {
  PR_NUM=$1

  get_repo_owner_and_name
  info "review_pr_gh: OWNER=${OWNER}, PROJECT=${PROJECT}, GH_HOST=${GH_HOST}"

  declare token_file="${DIR}/.ghub_oauth_pr_review"
  info "review_pr_gh: token_file=${token_file}"

  if [ -z "${GH_HOST}" ]; then
    gh auth login --with-token <"${token_file}"
  else
    gh auth login --hostname "${GH_HOST}" --with-token <"${token_file}"
  fi

  api_result=$(gh pr view ${PR_NUM} --json baseRefName,headRefName)

  # jq -r emits strings without wrapping quotes
  FROM=$(echo "${api_result}" | jq -r '.headRefName')

  if [ -z "$FROM" ] || [ "$FROM" = "null" ]; then
    fail_with_msg "gh client call failed: api_result=${api_result}"
  fi

  TO=$(echo "${api_result}" | jq -r '.baseRefName')
  info "TO=${TO}"

  review_branch "${FROM}" "${TO}" "${DEFAULT_TEMP_BRANCH}"
}

# Discards all changes from TEMP_BRANCH and deletes it.
# Checks out the stored branch and pulls latest.
# Optional argument provided can override the stored branch name
# Input: RESTORE_BRANCH (optional, to override any stored branch name)
function review_finished {
  #  uncomment for verbose echoing of everything happening
  #set -o xtrace
  RESTORE_BRANCH=$1 # optional branch to restore instead of STORED_BRANCH_NAME

  read_stored_branch_name "${SCRATCH_DIR}"
  [ -z "${1:-}" ] && RESTORE_BRANCH="${STORED_BRANCH_NAME}"

  can_delete_stored_branch_name=''

  if [ -z "$RESTORE_BRANCH" ]; then
    RESTORE_BRANCH=$(git remote show origin | grep 'HEAD branch' | cut -d' ' -f5)
  else
    can_delete_stored_branch_name='1'
  fi
  # If it's still empty, we fail.
  if [ -z "$RESTORE_BRANCH" ]; then
    fail_with_msg "unable to determine RESTORE_BRANCH"
  fi

  output RESTORE_BRANCH="${RESTORE_BRANCH}"

  get_current_branch

  # TODO clean up this MY_CURRENT_BRANCH and TEMP_BRANCH thing and get rid of hard-coded 'review'
  # Likely: store temp branch in the data file along with the branch to restore and then do safety check
  # here vs that value. So if we stored temp branch of 'review' but our current branch is 'main', then abort.
  if [ "${MY_CURRENT_BRANCH}" != "review" ]; then
    fail_with_msg "expected current branch: review. actual current branch: ${MY_CURRENT_BRANCH}"
  fi

  [ -z "${2:-}" ] && TEMP_BRANCH=review
  output "review_finished: TEMP_BRANCH=${TEMP_BRANCH}, RESTORE_BRANCH=${RESTORE_BRANCH}"

  git merge --abort

  declare -A restore_branch_info
  get_branch_info "${RESTORE_BRANCH}" restore_branch_info

  if [ -n "${restore_branch_info[remote]}" ]; then
    git fetch origin "${RESTORE_BRANCH}" || fail_with_msg "git fetch origin ${RESTORE_BRANCH}"
  fi

  git checkout "${RESTORE_BRANCH}" || fail_with_msg "git checkout ${RESTORE_BRANCH}"

  if [ -n "${restore_branch_info[remote]}" ]; then
    git pull origin "${RESTORE_BRANCH}" || fail_with_msg "git pull origin ${RESTORE_BRANCH}"
  fi

  if [ "$can_delete_stored_branch_name" = "1" ]; then
    delete_stored_branch_name "${SCRATCH_DIR}"
  fi

  git branch -D "${TEMP_BRANCH}" || fail_with_msg "git branch -D ${TEMP_BRANCH}"
}

function help {
  echo "sorry, there is no help yet"
}

the_cmd="$1"
shift

case "${the_cmd}" in
pr)
  review_pr_gh "$@"
  ;;
branch)
  review_branch "$@"
  ;;

finished)
  review_finished "$@"
  ;;
help)
  help "$@"
  ;;
*)
  fail_with_msg "unknown command: ${the_cmd}"
  ;;
esac
