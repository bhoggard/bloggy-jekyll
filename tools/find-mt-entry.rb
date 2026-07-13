#!/usr/bin/env ruby
# frozen_string_literal: true

# Searches the Movable Type database for entries that the main migration
# (migrate-mt-to-jekyll.rb) may have missed. That script only exports rows
# with entry_blog_id = 1, entry_status = 2 (published), and
# entry_class = 'entry', so a post can be absent from _posts/ because it
# lives in another blog in the same MT install, was left unpublished, or
# was created as a "page". This tool searches across ALL blogs, statuses,
# and classes so you can see exactly why a given URL has no migrated post.
#
# Motivating case: https://bloggy.com/2012/12/the-end-of-artcat-calendar/
# is linked externally and 404s; the migrated posts end in April 2011.
#
# Usage:
#   bundle install --with migration   # if not already done
#   bundle exec ruby tools/find-mt-entry.rb [search-term]   # default: "artcat calendar"
#   bundle exec ruby tools/find-mt-entry.rb --id 7042       # dump one entry in full
#
# The search term is matched (case-insensitively, words in order) against
# both entry_title and entry_basename; underscores/dashes/spaces are
# treated as equivalent, so "the-end-of-artcat-calendar" finds the MT
# basename "the_end_of_artcat_calendar".
#
# Once the entry is identified, --id prints its full text so the post can
# be recreated by hand, or migrate-mt-to-jekyll.rb can be adjusted/re-run
# if it turns out a whole class of entries was skipped.

require 'mysql2'

my_cnf = File.read(File.expand_path('~/.my.cnf'))
db_pass = my_cnf[/password="(.*)"/, 1]
client = Mysql2::Client.new(host: '127.0.0.1', username: 'root', password: db_pass, database: 'movable_type')

STATUS_NAMES = { 1 => 'draft', 2 => 'published', 3 => 'review', 4 => 'scheduled', 5 => 'junk', 6 => 'unpublished' }.freeze

def print_row(row)
  status = STATUS_NAMES[row['entry_status']] || row['entry_status'].to_s
  puts "entry_id=#{row['entry_id']}  blog_id=#{row['entry_blog_id']}  status=#{status}  " \
       "class=#{row['entry_class']}  authored_on=#{row['entry_authored_on']}"
  puts "  basename: #{row['entry_basename']}"
  puts "  title:    #{row['entry_title']}"
end

if ARGV[0] == '--id'
  id = Integer(ARGV.fetch(1) { abort 'Usage: find-mt-entry.rb --id ENTRY_ID' })
  stmt = client.prepare(<<~SQL)
    SELECT entry_id, entry_blog_id, entry_status, entry_class, entry_title,
           entry_basename, entry_authored_on, entry_convert_breaks,
           entry_text, entry_text_more
    FROM mt_entry WHERE entry_id = ?
  SQL
  row = stmt.execute(id).first or abort "No entry with id #{id}"
  print_row(row)
  puts "  text_format: #{row['entry_convert_breaks']}"
  puts
  puts '----- entry_text -----'
  puts row['entry_text']
  more = row['entry_text_more'].to_s
  unless more.empty?
    puts '----- entry_text_more -----'
    puts more
  end
  exit
end

term = ARGV.empty? ? 'artcat calendar' : ARGV.join(' ')
# Words in order, any separator between them; _ / - / space are interchangeable
# so URL slugs, MT basenames, and titles all match the same query.
pattern = '%' + term.split(/[\s_-]+/).join('%') + '%'

stmt = client.prepare(<<~SQL)
  SELECT entry_id, entry_blog_id, entry_status, entry_class, entry_title,
         entry_basename, entry_authored_on
  FROM mt_entry
  WHERE REPLACE(REPLACE(entry_basename, '_', ' '), '-', ' ') LIKE ?
     OR REPLACE(REPLACE(entry_title, '_', ' '), '-', ' ') LIKE ?
  ORDER BY entry_authored_on
SQL
rows = stmt.execute(pattern, pattern).to_a

if rows.empty?
  puts "No entries matching #{term.inspect} in any blog/status/class."
  puts 'The post may predate this database dump or live in a different system entirely.'
else
  rows.each { |row| print_row(row) }
  puts
  puts "#{rows.size} match(es). Entries outside blog_id=1/status=published/class=entry were"
  puts 'skipped by migrate-mt-to-jekyll.rb - that is likely why the URL 404s.'
  puts 'Dump one in full with: bundle exec ruby tools/find-mt-entry.rb --id ENTRY_ID'
end
