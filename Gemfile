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

# Local path dependency, like spree_host's own Gemfile — spree_pos is
# unreleased (Phase 1/2 of the multi-POS/multi-location plan). Mirrors
# spree_host's SPREE_POS_PATH-less convention: both repos are checked out as
# siblings under the same parent directory.
spree_pos_opts = ENV['SPREE_POS_PATH'] ? { path: ENV['SPREE_POS_PATH'] } : { path: '../spree_pos' }
gem 'spree_pos', spree_pos_opts

gem 'spree_dev_tools', '>= 0.6.0.rc1'

if ENV['DB'] == 'mysql'
  gem 'mysql2'
elsif ENV['DB'] == 'postgres'
  gem 'pg'
else
  gem 'sqlite3'
end

gem 'propshaft'

gemspec
