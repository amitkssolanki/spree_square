source 'https://rubygems.org'

gem 'rails-controller-testing'

# Pinned to the released 5.6.x line (matching spree_host) rather than tracking
# spree/spree's main branch, which is mid-refactor toward v6 (e.g. spree_admin
# has moved around between tags and main) and isn't safe to develop against.
spree_opts = if ENV['SPREE_PATH']
                { 'path': ENV['SPREE_PATH'] }
             else
                '~> 5.6.0'
             end
gem 'spree', spree_opts
gem 'spree_admin', spree_opts

gem 'spree_dev_tools', '>= 0.6.0.rc1'

if ENV['DB'] == 'mysql'
  gem 'mysql2'
elsif ENV['DB'] == 'postgres'
  gem 'pg'
else
  gem 'sqlite3'
end

gem 'propshaft'

# Pinned below 3.0: json 3.0.2's JSON.parse dropped the second positional
# options argument that Rails 8.1.3.1's ActiveSupport::JSON.decode (and so
# every t.json column, including the encrypted-column metadata `encrypts`
# writes) still calls with. Neither this gem nor spree_pos commits a
# Gemfile.lock (normal for a library, not an app), so a fresh `bundle
# install` in a new worktree/clone can freely resolve into the broken
# version and every JSON-column read raises `ArgumentError: wrong number
# of arguments (given 2, expected 1)`. Found during Phase 2 integration
# (see the parallel-agent reports) -- not a spree_square code defect.
gem 'json', '< 3'

gemspec
