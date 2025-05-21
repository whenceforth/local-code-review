# Gemfile
source 'https://rubygems.org'

gem 'fileutils', '~>1.7.3'
gem 'git', '~>3.1.0'
gem 'json', '~>2.12.0'
gem 'open3', '~>0.2.1'

# If you don't need GitLab support, you can omit the gem: bundle install --without gitlab_support
group :gitlab_support do
  gem 'gitlab' # Hmm. Specifying a version here doesn't seem to work. Without a version specified I get 5.1.0 installed.
end
