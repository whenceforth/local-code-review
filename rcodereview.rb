#!/usr/bin/env ruby

require 'git'
require 'fileutils'
require 'json'
require 'open3' # For capturing stderr from system calls if needed

# --- Configuration and Globals ---
SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG = {}
DEFAULT_CONFIG_PATH = File.join(SCRIPT_DIR, '.codereview.config.default')
OVERRIDE_CONFIG_PATH = File.join(SCRIPT_DIR, '.codereview.config')

# --- Logging ---
def debug(message)
  puts "CR.DEBUG #{message}" if CONFIG['CR_LOG_DEBUG'] == '1' || CONFIG['CR_LOG_INFO'] == '1'
end

def info(message)
  puts "CR.INFO  #{message}" if CONFIG['CR_LOG_INFO'] == '1'
end

def output(message)
  puts "CR       #{message}"
end

def fail_with_msg(message)
  warn "Exiting due to failure: #{message}" # To stderr
  exit 1
end

# --- Helper Functions ---
def load_config_file(file_path)
  loaded_cfg = {}
  return loaded_cfg unless File.exist?(file_path) && File.readable?(file_path)

  File.foreach(file_path) do |line|
    line.strip!
    next if line.start_with?('#') || line.empty?

    # Match export KEY=VALUE, export KEY="VALUE", KEY=VALUE, KEY="VALUE"
    if match = line.match(/^(?:export\s+)?([^=]+)=(.*)/)
      key = match[1].strip
      value = match[2].strip.gsub(/^["']|["']$/, '') # Remove surrounding quotes
      loaded_cfg[key] = value
    end
  end
  loaded_cfg
end

def load_configuration
  CONFIG.merge!(load_config_file(DEFAULT_CONFIG_PATH))
  if File.exist?(OVERRIDE_CONFIG_PATH) && File.readable?(OVERRIDE_CONFIG_PATH)
    info "using override config: #{OVERRIDE_CONFIG_PATH}"
    CONFIG.merge!(load_config_file(OVERRIDE_CONFIG_PATH))
  else
    info "using default config only"
  end
  # Set defaults if not in config
  CONFIG['DEFAULT_TARGET_BRANCH'] ||= 'master'
  CONFIG['DEFAULT_TEMP_BRANCH'] ||= 'review'
  CONFIG['SCRATCH_DIR'] ||= File.join(ENV['HOME'], '.tmp', 'codereview')
end

def confirm_action
  return unless CONFIG['CR_CONFIRM'] && !CONFIG['CR_CONFIRM'].empty?

  print 'Do you want to continue? y/n: '
  shall_we = $stdin.gets.chomp

  unless %w[y Y].include?(shall_we)
    output "exiting on choice of '#{shall_we}'"
    exit 1
  end
  output 'continuing...'
end

# Memoization for git object
@git_object = nil
def g
  @git_object ||= Git.open(Dir.pwd) # Assumes running from within the repo
rescue ArgumentError => e
  fail_with_msg "Not a git repository or git command not found: #{e.message}"
end

REPO_DETAILS = {} # To store owner and project

def get_repo_owner_and_name
  return if REPO_DETAILS[:owner] && REPO_DETAILS[:project] # Already fetched

  begin
    origin_url = g.remote('origin').url
    debug "Original origin URL: #{origin_url}"
  rescue Git::Error
    fail_with_msg "Could not get URL for remote 'origin'. Ensure 'origin' remote is configured."
  end

  # Transform to common format for parsing
  # git@github.com:owner/project.git -> git://github.com/owner/project.git
  # https://github.com/owner/project.git -> https://github.com/owner/project.git
  common_format = origin_url.sub(/^git@([^:]+):/, 'git://\1/')
                            .sub(/^https:\/\//, 'https---') # temp for tr
                            .tr(':', '/')
                            .sub(/^https---/, 'https://')

  parts = common_format.split('/')
  # For git://github.com/owner/project.git -> parts are git, '', github.com, owner, project.git
  # For https://github.com/owner/project.git -> parts are https, '', github.com, owner, project.git
  if parts.length >= 5
    REPO_DETAILS[:owner] = parts[-2]
    REPO_DETAILS[:project] = parts[-1].sub(/\.git$/, '')
  else
    fail_with_msg "Could not parse owner and project from URL: #{origin_url} (parsed as #{common_format})"
  end

  debug "get_repo_owner_and_name: OWNER=#{REPO_DETAILS[:owner]}, PROJECT=#{REPO_DETAILS[:project]}"
end

def get_project_base_dir_name
  return REPO_DETAILS[:project_base_dir_name] if REPO_DETAILS[:project_base_dir_name]
  begin
    toplevel_dir = `git rev-parse --show-toplevel`.strip
    fail_with_msg "Could not get git top-level directory" if toplevel_dir.empty?
    REPO_DETAILS[:project_base_dir_name] = File.basename(toplevel_dir)
  rescue Errno::ENOENT
    fail_with_msg "git command not found. Please ensure git is installed and in your PATH."
  end
  REPO_DETAILS[:project_base_dir_name]
end

def get_branch_info(branch_name)
  branch_info = { 'branch' => branch_name }

  begin
    local_branch = g.branch(branch_name)
    # Note: g.branch(branch_name).config('merge') is not available in the gem.
    # We use g.config directly.
    tracking_ref = g.config("branch.#{branch_name}.merge")
    remote_name  = g.config("branch.#{branch_name}.remote")

    if tracking_ref.nil? || tracking_ref.empty?
      debug "get_branch_info: No tracking info for local branch '#{branch_name}'. Fetching 'origin #{branch_name}' to update remote-tracking branch."
      # This fetches the branch <branch_name> from origin to origin/<branch_name>
      # It does not set up local tracking if it wasn't already there.
      begin
        g.fetch('origin', ref: branch_name) # Fetches refs/heads/branch_name from origin
      rescue Git::Error => e
        debug "Fetch failed for origin/#{branch_name}: #{e.message}. This might be okay if the branch doesn't exist on origin."
      end
      # Re-check config (though fetch itself doesn't alter this local config)
      tracking_ref = g.config("branch.#{branch_name}.merge")
      remote_name  = g.config("branch.#{branch_name}.remote")
      debug "get_branch_info: After fetching, tracking=#{tracking_ref}"
    end

    branch_info['tracking'] = tracking_ref
    branch_info['remote'] = remote_name

    if remote_name && !remote_name.empty?
      branch_info['remote_url'] = g.remote(remote_name).url
    else
      # Fallback to 'origin' if specific remote for branch is not found/set
      branch_info['remote_url'] = g.remote('origin')&.url
    end

  rescue Git::Error => e
    debug "get_branch_info: Could not get full git config for branch #{branch_name}: #{e.message}"
    # Attempt to get at least the remote URL for origin if parts failed
    branch_info['remote_url'] ||= g.remote('origin')&.url
  end


  debug "get_branch_info: branch_name=#{branch_name}, tracking=#{branch_info['tracking']}, remote=#{branch_info['remote']}, remote_url=#{branch_info['remote_url']}"
  branch_info
end

def get_current_branch_name
  g.current_branch
end

CR_DATA_DETAILS = {}
def get_branch_data_dir_and_file(scratch_dir_base)
  return if CR_DATA_DETAILS[:file_path] # Already calculated

  get_repo_owner_and_name # Ensures REPO_DETAILS[:project] is populated
  project_name = REPO_DETAILS[:project]
  project_base_dir = get_project_base_dir_name

  CR_DATA_DETAILS[:dir_path] = File.join(scratch_dir_base, project_name)
  # Using PROJECT_BASE_DIR_NAME as the filename
  CR_DATA_DETAILS[:file_path] = File.join(CR_DATA_DETAILS[:dir_path], "#{project_base_dir}.txt")

  info "get_branch_data_dir_and_file: PROJECT=#{project_name}, CR_DATA_DIR=#{CR_DATA_DETAILS[:dir_path]}, CR_DATA_FILE=#{CR_DATA_DETAILS[:file_path]}"
  debug "get_branch_data_dir_and_file: CR_DATA_FILE=#{CR_DATA_DETAILS[:file_path]}"
end

def store_current_branch_name(scratch_dir_base = CONFIG['SCRATCH_DIR'])
  get_branch_data_dir_and_file(scratch_dir_base)
  current_branch = get_current_branch_name

  debug "store_current_branch_name: CR_DATA_FILE=#{CR_DATA_DETAILS[:file_path]}"
  FileUtils.mkdir_p(CR_DATA_DETAILS[:dir_path])
  File.write(CR_DATA_DETAILS[:file_path], current_branch)
  debug "remembered current branch (#{current_branch}) in #{CR_DATA_DETAILS[:file_path]}"
end

def read_stored_branch_name(scratch_dir_base = CONFIG['SCRATCH_DIR'])
  get_branch_data_dir_and_file(scratch_dir_base)
  debug "read_stored_branch_name: CR_DATA_FILE=#{CR_DATA_DETAILS[:file_path]}"

  stored_branch = CONFIG['DEFAULT_TARGET_BRANCH'] # Default
  if File.exist?(CR_DATA_DETAILS[:file_path])
    stored_branch = File.read(CR_DATA_DETAILS[:file_path]).strip
  else
    debug "Data file not found, using default: #{stored_branch}"
  end
  info "STORED_BRANCH_NAME=#{stored_branch}"
  stored_branch
end

def delete_stored_branch_name(scratch_dir_base = CONFIG['SCRATCH_DIR'])
  get_branch_data_dir_and_file(scratch_dir_base)
  if File.exist?(CR_DATA_DETAILS[:file_path])
    FileUtils.rm(CR_DATA_DETAILS[:file_path])
    debug "Deleted #{CR_DATA_DETAILS[:file_path]}"
  else
    output "failed to delete (not found): #{CR_DATA_DETAILS[:file_path]}"
  end
end

# --- Main Commands ---
def review_branch(feature_branch, target_branch = nil, temp_branch = nil)
  fail_with_msg "review_branch: must specify branch to review (FEATURE_BRANCH)" if feature_branch.nil? || feature_branch.empty?

  target_branch ||= CONFIG['DEFAULT_TARGET_BRANCH']
  temp_branch   ||= CONFIG['DEFAULT_TEMP_BRANCH']

  debug "review_branch: FEATURE_BRANCH=#{feature_branch}, TARGET_BRANCH=#{target_branch}, TEMP_BRANCH=#{temp_branch}"
  confirm_action

  store_current_branch_name(CONFIG['SCRATCH_DIR'])

  # Save any outstanding changes
  begin
    # Check if there are changes to stash
    status = g.status
    has_changes = status.changed.any? || status.added.any? || status.deleted.any? || status.untracked.any?
    if has_changes
      g.stash_save("codereview_autostash_#{Time.now.to_i}")
      info "Stashed local changes."
    else
      info "No local changes to stash."
    end
  rescue Git::Error => e
    # stash_save might fail if there's nothing to stash, depending on git version/config
    # The git gem handles "No local changes to save" gracefully.
    # If it's another error, we should report it.
    unless e.message.include?("No local changes to save")
      fail_with_msg "Failed to git stash save: #{e.message}"
    end
    info "No local changes to stash or stash command failed gracefully."
  end


  target_branch_info = get_branch_info(target_branch)

  # Get latest code for TARGET_BRANCH
  if target_branch_info['remote'] && !target_branch_info['remote'].empty?
    begin
      info "Fetching remote '#{target_branch_info['remote']}' for TARGET_BRANCH=#{target_branch}"
      # g.remote(target_branch_info['remote']).fetch # Fetches all from that remote
      system_must_succeed("git fetch #{target_branch_info['remote']} #{target_branch}")
    rescue Git::Error => e
      fail_with_msg "git fetch for remote '#{target_branch_info['remote']}' for TARGET_BRANCH=#{target_branch} failed: #{e.message}"
    end
  end

  begin
    info "Checking out TARGET_BRANCH=#{target_branch}"
    g.checkout(target_branch)
  rescue Git::Error => e
    fail_with_msg "git checkout for TARGET_BRANCH=#{target_branch} failed: #{e.message}"
  end

  if target_branch_info['remote'] && !target_branch_info['remote'].empty? && target_branch_info['tracking'] && !target_branch_info['tracking'].empty?
    begin
      info "Pulling remote '#{target_branch_info['remote']}' for TARGET_BRANCH=#{target_branch}"
      # g.pull(target_branch_info['remote'], target_branch) # This might try to pull the remote's "target_branch" name
      system_must_succeed("git pull #{target_branch_info['remote']} #{target_branch}")
    rescue Git::Error => e
      fail_with_msg "git pull for remote '#{target_branch_info['remote']}' for TARGET_BRANCH=#{target_branch} failed: #{e.message}"
    end
  end

  feature_branch_info = get_branch_info(feature_branch)

  # Get a local copy of the branch to be reviewed
  if feature_branch_info['remote'] && !feature_branch_info['remote'].empty?
    begin
      info "Fetching remote '#{feature_branch_info['remote']}' for FEATURE_BRANCH=#{feature_branch}"
      # g.remote(feature_branch_info['remote']).fetch
      system_must_succeed("git fetch #{feature_branch_info['remote']} #{feature_branch}")
    rescue Git::Error => e
      fail_with_msg "git fetch for remote '#{feature_branch_info['remote']}' for FEATURE_BRANCH=#{feature_branch} failed: #{e.message}"
    end
  end

  begin
    info "Checking out FEATURE_BRANCH=#{feature_branch}"
    g.checkout(feature_branch)
  rescue Git::Error => e
    fail_with_msg "git checkout #{feature_branch} failed: #{e.message}"
  end

  if feature_branch_info['remote'] && !feature_branch_info['remote'].empty? && feature_branch_info['tracking'] && !feature_branch_info['tracking'].empty?
    begin
      info "Pulling remote '#{feature_branch_info['remote']}' for FEATURE_BRANCH=#{feature_branch}"
      # g.pull(feature_branch_info['remote'], feature_branch)
      system_must_succeed("git pull #{feature_branch_info['remote']} #{feature_branch}")
    rescue Git::Error => e
      fail_with_msg "git pull for remote '#{feature_branch_info['remote']}' for FEATURE_BRANCH=#{feature_branch} failed: #{e.message}"
    end
  end

  # Now make a copy of TARGET_BRANCH to preview the merge with.
  info "Checking out TARGET_BRANCH=#{target_branch} again to create temp branch"
  g.checkout(target_branch)

  # Delete any older review branch
  if g.branches.local.map(&:name).include?(temp_branch)
    begin
      info "Deleting old temp branch '#{temp_branch}'"
      g.branch(temp_branch).delete(force: true)
    rescue Git::Error => e
      info "Could not delete old temp branch '#{temp_branch}' (may not exist or other issue): #{e.message}"
    end
  else
    info "No previous work branch found (using #{temp_branch})"
  end

  # Create a new work branch
  begin
    info "Creating new temp branch '#{temp_branch}' from '#{target_branch}'"
    g.branch(temp_branch).create
    g.checkout(temp_branch)
  rescue Git::Error => e
    fail_with_msg "git checkout -b #{temp_branch} failed: #{e.message}"
  end

  # Apply changes without committing. View diffs in IDE
  # The `git` gem's merge method auto-commits. We need to shell out for --no-commit.
  info "Merging #{feature_branch} into #{temp_branch} with --no-commit --no-ff"
  merge_command = "git merge --no-commit --no-ff \"#{feature_branch}\""
  output "Executing: #{merge_command}"
  system(merge_command) # We don't use system_must_succeed as merge can have conflicts

  # Check $?.success? for merge result. The bash script fails on merge error.
  unless $?.success?
    # A merge can "fail" (return non-zero) due to conflicts, which is expected for a preview.
    # The original script uses `|| fail_with_msg`. If a real error (not just conflict) occurs,
    # it's harder to distinguish here without parsing `git merge` output.
    # For now, we'll just warn. User should check status.
    output "WARN: `git merge --no-commit` exited with code #{$?.exitstatus}. This might indicate merge conflicts to review."
  end


  output ""
  output "git status: "
  output ""
  system("git status") # Using system for rich output

  output ""
  output ""
  output "FEATURE_BRANCH=#{feature_branch}, TARGET_BRANCH=#{target_branch}, TEMP_BRANCH=#{temp_branch}"
  output ""
  output "When finished with review, you can discard the preview merge by running:"
  output "             #{File.join(SCRIPT_DIR, File.basename($0))} finished"
  output ""
end

def review_pr_gh(pr_num)
  fail_with_msg "PR Number not provided" if pr_num.nil? || pr_num.empty?
  get_repo_owner_and_name # Populates REPO_DETAILS
  owner = REPO_DETAILS[:owner]
  project = REPO_DETAILS[:project]
  gh_host = CONFIG['GH_HOST']

  info "review_pr_gh: OWNER=#{owner}, PROJECT=#{project}, GH_HOST=#{gh_host}"

  token_file = File.join(SCRIPT_DIR, '.ghub_oauth_pr_review')
  info "review_pr_gh: token_file=#{token_file}"
  fail_with_msg "GitHub token file not found: #{token_file}" unless File.exist?(token_file)

  auth_command = "gh auth login --with-token < \"#{token_file}\""
  auth_command = "gh auth login --hostname \"#{gh_host}\" --with-token < \"#{token_file}\"" if gh_host && !gh_host.empty?

  output "Authenticating with gh CLI..."
  system_must_succeed(auth_command, show_output: false) # Don't show token success message directly

  output "Fetching PR info from GitHub API via gh CLI for PR ##{pr_num}..."
  # Using Open3 to capture stdout and stderr for better error reporting
  api_command = "gh pr view #{pr_num} --json baseRefName,headRefName --repo \"#{owner}/#{project}\""
  api_result_json, stderr_str, status = Open3.capture3(api_command)

  unless status.success?
    fail_with_msg "gh client call failed for PR ##{pr_num} on repo #{owner}/#{project}: #{stderr_str}"
  end

  begin
    api_result = JSON.parse(api_result_json)
  rescue JSON::ParserError => e
    fail_with_msg "Failed to parse JSON from gh API: #{e.message}. Response: #{api_result_json}"
  end

  from_branch = api_result['headRefName']
  to_branch = api_result['baseRefName']

  fail_with_msg "GitHub API call failed to return head branch (FROM): api_result=#{api_result_json}" if from_branch.nil? || from_branch.empty? || from_branch == "null"
  fail_with_msg "GitHub API call failed to return base branch (TO): api_result=#{api_result_json}" if to_branch.nil? || to_branch.empty? || to_branch == "null"

  info "FROM (head): #{from_branch}, TO (base): #{to_branch}"
  review_branch(from_branch, to_branch, CONFIG['DEFAULT_TEMP_BRANCH'])
end


def review_finished(restore_branch_override = nil, temp_branch_override = nil)
  # set -o xtrace equivalent can be very verbose; skipping for now.
  # Can add `set -x` to system calls if needed for specific commands.

  stored_branch_name = read_stored_branch_name(CONFIG['SCRATCH_DIR'])
  restore_branch = restore_branch_override || stored_branch_name
  temp_branch = temp_branch_override || CONFIG['DEFAULT_TEMP_BRANCH']

  can_delete_stored_file = false # Only delete if we successfully used the stored name and no override was given

  if restore_branch_override.nil? && (stored_branch_name && !stored_branch_name.empty? && stored_branch_name != CONFIG['DEFAULT_TARGET_BRANCH'])
    can_delete_stored_file = true
  end


  if restore_branch.nil? || restore_branch.empty?
    # Fallback: try to get default branch from remote 'origin'
    begin
      default_remote_head = `git remote show origin | grep 'HEAD branch' | cut -d' ' -f5`.strip
      restore_branch = default_remote_head unless default_remote_head.empty?
    rescue Errno::ENOENT
      fail_with_msg "git command not found to determine default remote head."
    end
  end

  fail_with_msg "Unable to determine RESTORE_BRANCH" if restore_branch.nil? || restore_branch.empty?
  output "RESTORE_BRANCH=#{restore_branch}"

  current_actual_branch = get_current_branch_name

  # Safety check: Ensure we are on the temp_branch before doing destructive things
  # The bash script has a hardcoded "review" here. Using the temp_branch variable is more robust.
  if current_actual_branch != temp_branch
    fail_with_msg "Expected current branch: #{temp_branch}. Actual current branch: #{current_actual_branch}. Aborting."
  end
  output "review_finished: TEMP_BRANCH=#{temp_branch}, RESTORE_BRANCH=#{restore_branch}"

  confirm_action

  # Abort any uncommitted merge (from --no-commit)
  # `git merge --abort` is the most reliable way.
  info "Attempting to abort any uncommitted merge..."
  system_must_succeed("git merge --abort", allow_fail_message: "Merge abort failed (maybe nothing to abort, or already committed).")

  restore_branch_info = get_branch_info(restore_branch)

  if restore_branch_info['remote'] && !restore_branch_info['remote'].empty?
    begin
      info "Fetching remote '#{restore_branch_info['remote']}' for RESTORE_BRANCH=#{restore_branch}"
      system_must_succeed("git fetch #{restore_branch_info['remote']} #{restore_branch}")
    rescue StandardError => e # Catch StandardError from system_must_succeed
      fail_with_msg "git fetch for remote '#{restore_branch_info['remote']}' for RESTORE_BRANCH=#{restore_branch} failed: #{e.message}"
    end
  end

  begin
    info "Checking out RESTORE_BRANCH=#{restore_branch}"
    g.checkout(restore_branch)
  rescue Git::Error => e
    fail_with_msg "git checkout #{restore_branch} failed: #{e.message}"
  end

  if restore_branch_info['remote'] && !restore_branch_info['remote'].empty? && restore_branch_info['tracking'] && !restore_branch_info['tracking'].empty?
    begin
      info "Pulling remote '#{restore_branch_info['remote']}' for RESTORE_BRANCH=#{restore_branch}"
      system_must_succeed("git pull #{restore_branch_info['remote']} #{restore_branch}")
    rescue StandardError => e
      fail_with_msg "git pull for remote '#{restore_branch_info['remote']}' for RESTORE_BRANCH=#{restore_branch} failed: #{e.message}"
    end
  end

  # Try to pop the stash if one was made by this script (more robust check needed for specific stash)
  # For simplicity, just trying to pop the latest. A more robust solution would save stash reference.
  begin
    latest_stash = g.stashes.latest
    if latest_stash && latest_stash.message.include?("codereview_autostash")
      info "Attempting to apply stashed changes..."
      g.stashes.apply # Or g.stashes.pop to remove it
      info "Stash applied. You may need to run `git stash drop` if it was a simple apply."
    end
  rescue Git::Error => e
    info "Could not apply stash (maybe no stash or conflicts): #{e.message}"
  rescue NoMethodError # If g.stashes.latest is nil
    info "No stashes found to apply."
  end


  if can_delete_stored_file
    delete_stored_branch_name(CONFIG['SCRATCH_DIR'])
  else
    debug "Not deleting stored branch name file (override used or was default)."
  end


  if g.branches.local.map(&:name).include?(temp_branch)
    begin
      info "Deleting temp branch '#{temp_branch}'"
      branch_del_cmd = "git branch -D #{temp_branch}"
      system_must_succeed(branch_del_cmd, allow_fail_message: "Failed to delete temp branch '#{temp_branch}'.")
    rescue Git::Error => e
      fail_with_msg "git branch -D #{temp_branch} failed: #{e.message}"
    end
  else
    info "Temp branch '#{temp_branch}' not found for deletion."
  end
  output "Review finished. Restored to #{restore_branch}."
end

def system_must_succeed(command, show_output: true, allow_fail_message: nil)
  output "Executing: #{command}" if show_output
  stdout_str, stderr_str, status = Open3.capture3(command)

  if show_output
    puts stdout_str unless stdout_str.empty?
    warn stderr_str unless stderr_str.empty? # To stderr
  end

  unless status.success?
    message = "Command failed with status #{status.exitstatus}: #{command}\n#{stderr_str}"
    message = "#{allow_fail_message}\n#{message}" if allow_fail_message
    fail_with_msg(message)
  end
  stdout_str # Return stdout for potential further use
end


def print_help
  output "Usage: #{$0} <command> [options]"
  output "Commands:"
  output "  pr <pr_number>              - Prepares a review for a GitHub Pull Request using 'gh' CLI."
  output "  branch <feature_branch> [target_branch] [temp_branch] - Prepares a review for a feature branch."
  output "  finished [restore_branch] [temp_branch] - Cleans up after a review and restores the original branch."
  output "  help                        - Shows this help message."
  output "\nConfiguration is read from '.codereview.config.default' and '.codereview.config'."
  output "Key config options (can be set in config files):"
  output "  CR_LOG_DEBUG=1              - Enable debug logging."
  output "  CR_LOG_INFO=1               - Enable info logging (also enables debug)."
  output "  CR_CONFIRM=1                - Ask for confirmation before proceeding with destructive actions."
  output "  DEFAULT_TARGET_BRANCH       - Default: master"
  output "  DEFAULT_TEMP_BRANCH         - Default: review"
  output "  SCRATCH_DIR                 - Default: ~/.tmp/codereview"
  output "  GH_HOST                     - GitHub Enterprise hostname for 'gh' CLI (e.g., github.example.com)"
end

# --- Main Script Execution ---
if __FILE__ == $0
  load_configuration

  command = ARGV.shift
  case command
  when 'pr'
    pr_num = ARGV.shift
    fail_with_msg "PR number is required for 'pr' command." unless pr_num
    review_pr_gh(pr_num)
  when 'branch'
    feature_branch = ARGV.shift
    target_branch = ARGV.shift # optional
    temp_branch = ARGV.shift   # optional
    fail_with_msg "Feature branch name is required for 'branch' command." unless feature_branch
    review_branch(feature_branch, target_branch, temp_branch)
  when 'finished'
    restore_branch = ARGV.shift # optional
    temp_branch_override = ARGV.shift # optional
    review_finished(restore_branch, temp_branch_override)
  when 'help'
    print_help
  else
    if command.nil? || command.empty?
      fail_with_msg "No command provided. Use 'help' for options."
    else
      fail_with_msg "Unknown command: #{command}. Use 'help' for options."
    end
  end
end
