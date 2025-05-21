#!/usr/bin/env ruby

require 'git'
require 'fileutils'
require 'json'
require 'open3' # For capturing stderr from system calls if needed
begin
  require 'gitlab' # For GitLab API interaction
rescue LoadError
  # Gitlab gem not used if not doing GitLab PR reviews, so only warn then.
end

# --- Configuration and Globals ---
SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
CONFIG = {}
DEFAULT_CONFIG_PATH = File.join(SCRIPT_DIR, '.codereview.config.default')
OVERRIDE_CONFIG_PATH = File.join(SCRIPT_DIR, '.codereview.config')

REPO_DETAILS = {
  platform: nil,            # :github or :gitlab
  host: nil,                # Actual hostname from URL
  api_base_url: nil,        # e.g. https://api.github.com or https://gitlab.com/api/v4
  repo_path: nil,           # Path part of the repo, e.g., "owner/project" or "group/subgroup/project"
  project_name: nil,        # The last part of the repo_path, e.g., "project"
  owner_or_group: nil       # "owner" for GitHub, "group/subgroup" for GitLab
}

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
    if match = line.match(/^(?:export\s+)?([^=]+)=(.*)/)
      key = match[1].strip
      value = match[2].strip.gsub(/^["']|["']$/, '')
      loaded_cfg[key] = value
    end
  end
  loaded_cfg
end

def expand_config_path_if_present(config, name)
  item = config[name]
  return config unless item.to_s.length > 0

  config[name] = File.expand_path(item)
  config
end

def load_configuration
  CONFIG.merge!(load_config_file(DEFAULT_CONFIG_PATH))
  override_config_path = OVERRIDE_CONFIG_PATH
  if override_config_path
    override_config_path = File.expand_path(override_config_path)
    if File.exist?(override_config_path) && File.readable?(override_config_path)
      info "using override config: #{override_config_path}"
      CONFIG.merge!(load_config_file(override_config_path))
    else
      info "using default config only"
    end
  end

  # GitHub defaults
  # Set defaults if not in config OR if they are empty strings
  CONFIG['GH_HOST'] = 'github.com' if CONFIG['GH_HOST'].to_s.empty?

  CONFIG['GH_API_BASE_URL'] = "https://api.#{CONFIG['GH_HOST']}" if CONFIG['GH_API_BASE_URL'].to_s.empty? # Standard for public/GHE

  expand_config_path_if_present(CONFIG, 'GH_TOKEN_FILE')
  CONFIG['GH_TOKEN_FILE'] = File.join(SCRIPT_DIR, '.ghub_oauth_pr_review') if CONFIG['GH_TOKEN_FILE'].to_s.empty?

  # GitLab defaults
  CONFIG['GL_HOST'] = 'gitlab.com' if CONFIG['GL_HOST'].to_s.empty?
  CONFIG['GITLAB_API_ENDPOINT'] = "https://#{CONFIG['GL_HOST']}/api/v4" if CONFIG['GITLAB_API_ENDPOINT'].to_s.empty?

  expand_config_path_if_present(CONFIG, 'GL_TOKEN_FILE')
  CONFIG['GL_TOKEN_FILE'] = File.join(SCRIPT_DIR, '.glab_oauth_pr_review') if CONFIG['GL_TOKEN_FILE'].to_s.empty?

  CONFIG['DEFAULT_TARGET_BRANCH'] = 'master' if CONFIG['DEFAULT_TARGET_BRANCH'].to_s.empty?
  CONFIG['DEFAULT_TEMP_BRANCH'] = 'review' if CONFIG['DEFAULT_TEMP_BRANCH'].to_s.empty?

  expand_config_path_if_present(CONFIG,'SCRATCH_DIR')
  CONFIG['SCRATCH_DIR'] = File.join(ENV['HOME'], '.tmp', 'codereview') if CONFIG['SCRATCH_DIR'].to_s.empty?
end

def confirm_action
  return unless CONFIG['CR_CONFIRM'] && !CONFIG['CR_CONFIRM'].empty?
  print 'Do you want to continue? y/n: '
  shall_we = $stdin.gets.chomp.downcase
  unless %w[y yes].include?(shall_we)
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

def get_platform_and_repo_details
  return if REPO_DETAILS[:platform] # Already determined

  begin
    origin_url = g.remote('origin').url
    debug "Parsing origin URL: #{origin_url}"
  rescue Git::Error
    fail_with_msg "Could not get URL for remote 'origin'. Ensure 'origin' remote is configured."
  end

  repo_host = nil
  repo_path_match = nil

  if origin_url.match(%r{^(?:git@|https?://)([^:/]+)[:/](.+?)(?:\.git)?$})
    # Matches:
    # git@github.com:owner/project.git  -> host=github.com, path=owner/project
    # https://github.com/owner/project.git -> host=github.com, path=owner/project
    # git@gitlab.example.com:group/subgroup/project.git -> host=gitlab.example.com, path=group/subgroup/project
    # https://gitlab.example.com/group/subgroup/project.git -> host=gitlab.example.com, path=group/subgroup/project
    repo_host = $1
    repo_path_match = $2
  else
    fail_with_msg "Could not parse host and path from origin URL: #{origin_url}"
  end

  REPO_DETAILS[:host] = repo_host.downcase
  REPO_DETAILS[:repo_path] = repo_path_match

  # Determine platform
  gh_host_config = CONFIG['GH_HOST']&.downcase
  gl_host_config = CONFIG['GL_HOST']&.downcase

  if REPO_DETAILS[:host] == gh_host_config || (gh_host_config == "github.com" && REPO_DETAILS[:host] == "github.com")
    REPO_DETAILS[:platform] = :github
    REPO_DETAILS[:api_base_url] = CONFIG['GH_API_BASE_URL']
    parts = REPO_DETAILS[:repo_path].split('/')
    REPO_DETAILS[:owner_or_group] = parts.length > 1 ? parts[0...-1].join('/') : nil # Could be just owner, or empty if repo is at root (rare for GH)
    REPO_DETAILS[:project_name] = parts.last
  elsif REPO_DETAILS[:host] == gl_host_config || (gl_host_config == "gitlab.com" && REPO_DETAILS[:host] == "gitlab.com")
    REPO_DETAILS[:platform] = :gitlab
    REPO_DETAILS[:api_base_url] = CONFIG['GITLAB_API_ENDPOINT']
    # For GitLab, repo_path is usually "group/subgroup/project"
    REPO_DETAILS[:owner_or_group] = File.dirname(REPO_DETAILS[:repo_path]) unless REPO_DETAILS[:repo_path].count('/') == 0
    REPO_DETAILS[:owner_or_group] = nil if REPO_DETAILS[:owner_or_group] == '.'
    REPO_DETAILS[:project_name] = File.basename(REPO_DETAILS[:repo_path])
  else
    fail_with_msg "Origin URL host '#{REPO_DETAILS[:host]}' does not match configured GH_HOST ('#{gh_host_config}') or GL_HOST ('#{gl_host_config}')."
  end

  debug "Platform detection: #{REPO_DETAILS.inspect}"
end


REPO_DETAILS_LEGACY = {} # To store owner and project for bash script compatibility
def get_repo_owner_and_name_legacy_compat
  return if REPO_DETAILS_LEGACY[:owner] && REPO_DETAILS_LEGACY[:project]
  get_platform_and_repo_details # Ensure new detection runs

  if REPO_DETAILS[:platform] == :github
    # For GitHub, owner_or_group is typically the owner, repo_path is owner/project
    path_parts = REPO_DETAILS[:repo_path].split('/')
    REPO_DETAILS_LEGACY[:owner] = path_parts.first if path_parts.length > 1
    REPO_DETAILS_LEGACY[:project] = path_parts.last
  elsif REPO_DETAILS[:platform] == :gitlab
    # For GitLab, owner_or_group can be group/subgroup, repo_path is group/subgroup/project
    # This mapping is imperfect for "owner" but "project" should be fine.
    REPO_DETAILS_LEGACY[:owner] = REPO_DETAILS[:owner_or_group] # This will be the full group path
    REPO_DETAILS_LEGACY[:project] = REPO_DETAILS[:project_name]
  else
    fail_with_msg "Cannot determine legacy owner/project for unknown platform."
  end
  debug "get_repo_owner_and_name_legacy_compat: OWNER=#{REPO_DETAILS_LEGACY[:owner]}, PROJECT=#{REPO_DETAILS_LEGACY[:project]}"
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
    tracking_ref = g.config("branch.#{branch_name}.merge")
    remote_name  = g.config("branch.#{branch_name}.remote")

    if (tracking_ref.nil? || tracking_ref.empty?) && (remote_name.nil? || remote_name.empty?)
      debug "get_branch_info: No local tracking info for '#{branch_name}'. Assuming 'origin' and fetching 'origin #{branch_name}'."
      remote_name = 'origin' # Default to origin if not configured
      begin
        g.fetch(remote_name, ref: branch_name)
      rescue Git::Error => e
        debug "Fetch failed for #{remote_name}/#{branch_name}: #{e.message}. This might be okay if the branch doesn't exist on remote."
      end
      tracking_ref = g.config("branch.#{branch_name}.merge") # Re-check
      remote_name_check = g.config("branch.#{branch_name}.remote")
      remote_name = remote_name_check if remote_name_check && !remote_name_check.empty?
    end
    branch_info['tracking'] = tracking_ref
    branch_info['remote'] = remote_name
    branch_info['remote_url'] = g.remote(remote_name || 'origin')&.url if remote_name || g.remotes.map(&:name).include?('origin')
  rescue Git::Error => e
    debug "get_branch_info: Could not get full git config for branch #{branch_name}: #{e.message}"
    branch_info['remote_url'] ||= g.remote('origin')&.url if g.remotes.map(&:name).include?('origin')
  end
  debug "get_branch_info results: #{branch_info.inspect}"
  branch_info
end

def get_current_branch_name
  g.current_branch
end

CR_DATA_DETAILS = {}
def get_branch_data_dir_and_file(scratch_dir_base)
  return if CR_DATA_DETAILS[:file_path]

  get_platform_and_repo_details # Ensures REPO_DETAILS[:project_name] is populated
  # Use the specific project name from the platform details for directory naming
  project_identifier_for_file = REPO_DETAILS[:project_name]
  fail_with_msg "Could not determine project name for data file path." if project_identifier_for_file.nil? || project_identifier_for_file.empty?

  project_base_dir = get_project_base_dir_name # Local directory name

  CR_DATA_DETAILS[:dir_path] = File.join(scratch_dir_base, project_identifier_for_file) # Use actual project name
  CR_DATA_DETAILS[:file_path] = File.join(CR_DATA_DETAILS[:dir_path], "#{project_base_dir}.txt") # Local unique file

  info "get_branch_data_dir_and_file: PROJECT_FOR_DIR=#{project_identifier_for_file}, CR_DATA_DIR=#{CR_DATA_DETAILS[:dir_path]}, CR_DATA_FILE=#{CR_DATA_DETAILS[:file_path]}"
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

def system_must_succeed(command, show_output: true, allow_fail_message: nil)
  output "Executing: #{command}" if show_output && CONFIG['CR_LOG_DEBUG'] == '1' # Only show command if debug
  stdout_str, stderr_str, status = Open3.capture3(command)

  # Always show output if command produces any, regardless of debug level, unless show_output is false.
  if show_output
    puts stdout_str unless stdout_str.empty?
    warn stderr_str unless stderr_str.empty?
  end

  unless status.success?
    message = "Command failed with status #{status.exitstatus}: #{command}\nSTDERR: #{stderr_str.strip}"
    message = "#{allow_fail_message}\n#{message}" if allow_fail_message
    fail_with_msg(message)
  end
  stdout_str
end

# --- Main Commands ---
def review_branch(feature_branch, target_branch = nil, temp_branch = nil)
  fail_with_msg "review_branch: must specify branch to review (FEATURE_BRANCH)" if feature_branch.nil? || feature_branch.empty?
  target_branch ||= CONFIG['DEFAULT_TARGET_BRANCH']
  temp_branch   ||= CONFIG['DEFAULT_TEMP_BRANCH']
  debug "review_branch: FEATURE_BRANCH=#{feature_branch}, TARGET_BRANCH=#{target_branch}, TEMP_BRANCH=#{temp_branch}"
  confirm_action
  store_current_branch_name(CONFIG['SCRATCH_DIR'])

  begin
    status = g.status
    has_changes = status.changed.any? || status.added.any? || status.deleted.any? || status.untracked.any?
    if has_changes
      g.stash_save("codereview_autostash_#{Time.now.to_i}")
      info "Stashed local changes."
    else
      info "No local changes to stash."
    end
  rescue Git::Error => e
    unless e.message.include?("No local changes to save")
      fail_with_msg "Failed to git stash save: #{e.message}"
    end
    info "No local changes to stash or stash command failed gracefully."
  end

  target_branch_info = get_branch_info(target_branch)
  target_remote = target_branch_info['remote'] || 'origin'
  info "Fetching remote '#{target_remote}' for TARGET_BRANCH=#{target_branch}"
  system_must_succeed("git fetch #{target_remote} #{target_branch}")
  info "Checking out TARGET_BRANCH=#{target_branch}"
  g.checkout(target_branch)
  info "Pulling remote '#{target_remote}' for TARGET_BRANCH=#{target_branch}"
  system_must_succeed("git pull #{target_remote} #{target_branch}")

  feature_branch_info = get_branch_info(feature_branch)
  feature_remote = feature_branch_info['remote'] || 'origin'
  info "Fetching remote '#{feature_remote}' for FEATURE_BRANCH=#{feature_branch}"
  system_must_succeed("git fetch #{feature_remote} #{feature_branch}")
  info "Checking out FEATURE_BRANCH=#{feature_branch}"
  g.checkout(feature_branch)
  info "Pulling remote '#{feature_remote}' for FEATURE_BRANCH=#{feature_branch}"
  system_must_succeed("git pull #{feature_remote} #{feature_branch}")

  info "Checking out TARGET_BRANCH=#{target_branch} again to create temp branch"
  g.checkout(target_branch)

  if g.branches.local.map(&:name).include?(temp_branch)
    info "Attempting to delete old temp branch '#{temp_branch}' via system call..."
    _stdout_str, stderr_str, status = Open3.capture3("git branch -D \"#{temp_branch}\"")
    if status.success?
      info "Successfully deleted old temp branch '#{temp_branch}'."
    else
      if stderr_str.match(/branch.*not found/i)
        info "Old temp branch '#{temp_branch}' was listed by gem but not found by CLI for deletion, or already gone."
      else
        info "Command `git branch -D \"#{temp_branch}\"` failed with: #{stderr_str.strip}. Continuing..."
      end
    end
  else
    info "No previous temp branch '#{temp_branch}' found (checked via gem API)."
  end

  info "Creating new temp branch '#{temp_branch}' from '#{target_branch}'"
  g.branch(temp_branch).create
  g.checkout(temp_branch)

  # Apply changes without committing. View diffs in IDE
  # The `git` gem's merge method auto-commits. We need to shell out for --no-commit.
  info "Merging #{feature_branch} into #{temp_branch} with --no-commit --no-ff"
  merge_command = "git merge --no-commit --no-ff \"#{feature_branch}\""
  output "Executing: #{merge_command}" # Show this specific command
  system(merge_command)
  unless $?.success?
    output "WARN: `git merge --no-commit` exited with code #{$?.exitstatus}. This might indicate merge conflicts to review."
  end

  output "\nStatus after attempted merge:\n"
  system("git status")
  output "\nFEATURE_BRANCH=#{feature_branch}, TARGET_BRANCH=#{target_branch}, TEMP_BRANCH=#{temp_branch}"
  output "\nWhen finished with review, you can discard the preview merge by running:"
  output "             #{File.join(SCRIPT_DIR, File.basename($0))} finished\n"
end

def review_pr_gh(pr_num)
  # Ensure REPO_DETAILS is populated for GitHub
  fail_with_msg "Not a GitHub repository according to origin URL." unless REPO_DETAILS[:platform] == :github

  gh_host_for_cli = REPO_DETAILS[:host] == 'github.com' ? '' : "--hostname \"#{REPO_DETAILS[:host]}\""
  token_file = CONFIG['GH_TOKEN_FILE']
  fail_with_msg "GitHub token file not found: #{token_file}" unless File.exist?(token_file)

  output "Authenticating with gh CLI for host '#{REPO_DETAILS[:host]}'..."
  # TODO: Use gh auth status
  # `gh auth login` can be interactive or error if already logged in.
  # Consider `gh auth status` or just letting `gh pr view` use existing auth / env vars.
  # Forcing login with token might be too intrusive if gh is already configured.
  # Let's rely on gh being pre-configured or `GH_TOKEN` env var.
  # system_must_succeed("gh auth login #{gh_host_for_cli} --with-token < \"#{token_file}\"", show_output: false)
  info "Assuming 'gh' CLI is authenticated or GH_TOKEN is set. Using token file for reference: #{token_file}"

  output "Fetching PR info from GitHub API via gh CLI for PR ##{pr_num}..."
  api_command = "gh pr view #{pr_num} --json baseRefName,headRefName --repo \"#{REPO_DETAILS[:repo_path]}\""
  api_result_json, stderr_str, status = Open3.capture3(api_command)

  unless status.success?
    fail_with_msg "gh client call failed for PR ##{pr_num} on repo #{REPO_DETAILS[:repo_path]}: #{stderr_str}"
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

  info "GitHub PR ##{pr_num}: FROM (head): #{from_branch}, TO (base): #{to_branch}"
  review_branch(from_branch, to_branch, CONFIG['DEFAULT_TEMP_BRANCH'])
end

def review_pr_gl(mr_iid)
  fail_with_msg "Not a GitLab repository according to origin URL." unless REPO_DETAILS[:platform] == :gitlab
  unless defined?(Gitlab)
    fail_with_msg "GitLab gem is not loaded. Please install it (`gem install gitlab`) and ensure it's in your Gemfile if using Bundler."
  end

  token_file = CONFIG['GL_TOKEN_FILE']
  fail_with_msg "GitLab token file not found: #{token_file}" unless File.exist?(token_file) && File.readable?(token_file)
  private_token = File.read(token_file).strip
  fail_with_msg "GitLab token is empty in #{token_file}." if private_token.empty?

  begin
    Gitlab.configure do |config|
      config.endpoint       = REPO_DETAILS[:api_base_url] # From get_platform_and_repo_details
      config.private_token  = private_token
    end
    debug "GitLab client configured for endpoint: #{Gitlab.endpoint}"

    # REPO_DETAILS[:repo_path] should be "group/project" or "group/subgroup/project"
    project_identifier = REPO_DETAILS[:repo_path]
    output "Fetching MR info from GitLab API for MR !#{mr_iid} in project '#{project_identifier}'..."

    mr = Gitlab.merge_request(project_identifier, mr_iid)
    from_branch = mr.source_branch
    to_branch = mr.target_branch

  rescue Gitlab::Error::Unauthorized => e
    fail_with_msg "GitLab API Error: Unauthorized. Check your token and endpoint. #{e.message}"
  rescue Gitlab::Error::NotFound => e
    fail_with_msg "GitLab API Error: Merge Request !#{mr_iid} or Project '#{project_identifier}' not found. #{e.message}"
  rescue Gitlab::Error => e # Catch other Gitlab errors
    fail_with_msg "GitLab API Error: #{e.class} - #{e.message}"
  rescue StandardError => e # Catch other unexpected errors like network issues
    fail_with_msg "An unexpected error occurred while fetching GitLab MR: #{e.message}"
  end

  fail_with_msg "GitLab API call failed to return source branch for MR !#{mr_iid}" if from_branch.nil? || from_branch.empty?
  fail_with_msg "GitLab API call failed to return target branch for MR !#{mr_iid}" if to_branch.nil? || to_branch.empty?

  info "GitLab MR !#{mr_iid}: FROM (source): #{from_branch}, TO (target): #{to_branch}"
  review_branch(from_branch, to_branch, CONFIG['DEFAULT_TEMP_BRANCH'])
end

def dispatch_review_pr(identifier)
  get_platform_and_repo_details # This will determine :platform and :repo_path

  case REPO_DETAILS[:platform]
  when :github
    review_pr_gh(identifier)
  when :gitlab
    review_pr_gl(identifier)
  else
    fail_with_msg "Could not determine Git hosting platform (GitHub/GitLab) from remote 'origin' URL or configuration."
  end
end

def review_finished(restore_branch_override = nil, temp_branch_override = nil)
  stored_branch_name = read_stored_branch_name(CONFIG['SCRATCH_DIR'])
  restore_branch = restore_branch_override || stored_branch_name
  temp_branch = temp_branch_override || CONFIG['DEFAULT_TEMP_BRANCH']
  can_delete_stored_file = restore_branch_override.nil? && (stored_branch_name && !stored_branch_name.empty? && stored_branch_name != CONFIG['DEFAULT_TARGET_BRANCH'])

  if restore_branch.nil? || restore_branch.empty?
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

  info "Attempting to abort any uncommitted merge (on branch '#{current_actual_branch}')..."
  system_must_succeed("git merge --abort", allow_fail_message: "Merge abort failed (maybe nothing to abort, or already committed).")

  restore_branch_info = get_branch_info(restore_branch)
  restore_remote = restore_branch_info['remote'] || 'origin'

  info "Fetching remote '#{restore_remote}' for RESTORE_BRANCH=#{restore_branch}"
  system_must_succeed("git fetch #{restore_remote} #{restore_branch}")

  info "Checking out RESTORE_BRANCH=#{restore_branch}"
  g.checkout(restore_branch)

  info "Pulling remote '#{restore_remote}' for RESTORE_BRANCH=#{restore_branch}"
  system_must_succeed("git pull #{restore_remote} #{restore_branch}")

  begin
    latest_stash = g.stashes.latest
    if latest_stash && latest_stash.message.include?("codereview_autostash")
      info "Attempting to apply stashed changes..."
      g.stashes.apply
      info "Stash applied. You may need to run `git stash drop` if it was a simple apply and you wish to remove it."
    end
  rescue Git::Error => e
    info "Could not apply stash (maybe no stash or conflicts): #{e.message}"
  rescue NoMethodError # If g.stashes.latest is nil
    info "No stashes found to apply."
  end

  delete_stored_branch_name(CONFIG['SCRATCH_DIR']) if can_delete_stored_file

  # Force delete the temp_branch
  if g.branches.local.map(&:name).include?(temp_branch)
    info "Deleting temp branch '#{temp_branch}' via system call..."
    system_must_succeed("git branch -D \"#{temp_branch}\"")
  else
    info "Temp branch '#{temp_branch}' not found for deletion (checked via gem API)."
  end
  output "Review finished. Restored to #{restore_branch}."
end

def print_help
  output "Usage: #{$0} <command> [options]"
  output "Commands:"
  output "  pr <pr_or_mr_number>        - Prepares a review for a GitHub PR or GitLab MR."
  output "  branch <feature_branch> [target_branch] [temp_branch] - Prepares a review for a feature branch."
  output "  finished [restore_branch] [temp_branch] - Cleans up and restores original branch."
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
    identifier = ARGV.shift
    # IID stands for Internal ID.
    # While GitHub uses "Pull Request number" (which is unique within a repository),
    # GitLab uses "Internal ID" (IID) for its Merge Requests. The IID is also unique
    # within a single repository/project.
    fail_with_msg "PR/MR number or IID is required for 'pr' command." unless identifier
    dispatch_review_pr(identifier)
  when 'branch'
    feature_branch = ARGV.shift
    target_branch = ARGV.shift # optional
    temp_branch = ARGV.shift # optional
    fail_with_msg "Feature branch name is required for 'branch' command." unless feature_branch
    review_branch(feature_branch, target_branch, temp_branch)
  when 'finished'
    restore_branch_override = ARGV.shift # optional
    temp_branch_override = ARGV.shift # optional
    review_finished(restore_branch_override, temp_branch_override)
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
