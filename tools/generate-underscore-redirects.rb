#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates client-side redirect stubs for the underscore-basename variant of
# each post's URL (e.g. /2009/11/nikhil_chopra_new_museum.html), which the
# original Movable Type site tolerated alongside the dash-based canonical URL
# (confirmed empirically: both variants returned 200 on the live legacy site).
# The new Jekyll site only generates the dash-based permalink, so any
# external link or bookmark using the underscore form 404s. 2,614 of 2,753
# posts have an underscore in their basename, so a Cloudflare Pages
# `_redirects` file (2,100-rule limit) can't cover this - each gets its own
# static stub instead, same approach as generate-mt-redirects.rb.
#
# Usage:
#   bundle install --with migration   # if not already done for migrate-mt-to-jekyll.rb
#   bundle exec ruby tools/generate-underscore-redirects.rb

require 'mysql2'
require 'fileutils'
require 'json'

BLOG_ID = 1
REPO = File.expand_path('..', __dir__)

my_cnf = File.read(File.expand_path('~/.my.cnf'))
db_pass = my_cnf[/password="(.*)"/, 1]
client = Mysql2::Client.new(host: '127.0.0.1', username: 'root', password: db_pass, database: 'movable_type')

def slugify(basename)
  basename.gsub('_', '-')
end

entries = client.query(<<~SQL, cache_rows: false)
  SELECT entry_id, entry_basename, entry_authored_on
  FROM mt_entry
  WHERE entry_blog_id = #{BLOG_ID} AND entry_status = 2 AND entry_class = 'entry'
    AND entry_basename LIKE '%\\_%'
SQL

written = 0
skipped_same = 0

entries.each do |row|
  basename = row['entry_basename'].to_s
  slug = slugify(basename)
  next if slug == basename # no underscore actually present after all; shouldn't happen given the SQL filter

  ym = row['entry_authored_on'].strftime('%Y/%m')
  canonical = "/#{ym}/#{slug}.html"
  underscore_path = "/#{ym}/#{basename}.html"

  if underscore_path == canonical
    skipped_same += 1
    next
  end

  output_dir = File.join(REPO, ym.split('/')[0], ym.split('/')[1])
  FileUtils.mkdir_p(output_dir)
  output_file = File.join(output_dir, "#{basename}.html")

  # Don't clobber a real file that happens to already exist at this exact path
  # (shouldn't occur since canonical permalinks are always the dashed form,
  # but guard against it in case a post's basename has no dashes to differ).
  if File.exist?(output_file) && !File.read(output_file).include?('Redirecting')
    skipped_same += 1
    next
  end

  html = <<~HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="0; url=#{canonical}">
    <link rel="canonical" href="#{canonical}">
    <title>Redirecting&hellip;</title>
    <script>location.replace(#{canonical.to_json});</script>
    </head>
    <body>
    <p>This page has moved. If you are not redirected automatically, <a href="#{canonical}">click here</a>.</p>
    </body>
    </html>
  HTML

  File.write(output_file, html)
  written += 1
end

puts "Redirect stubs written: #{written}"
puts "Skipped (underscore path matches canonical, or a conflicting file exists): #{skipped_same}"
