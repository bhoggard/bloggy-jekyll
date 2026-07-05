# frozen_string_literal: true

source "https://rubygems.org"

gem "jekyll-theme-chirpy", "~> 7.5"

gem "html-proofer", "~> 5.0", group: :test

# Only needed for tools/migrate-mt-to-jekyll.rb. Not installed by a plain
# `bundle install`; opt in with `bundle install --with migration`.
group :migration, optional: true do
  gem "mysql2", "~> 0.5"
  gem "RedCloth", "~> 4.3"
  gem "tzinfo", "~> 2.0"
end
