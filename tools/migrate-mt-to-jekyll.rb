#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts published entries from a Movable Type database into Jekyll posts
# under _posts/, preserving the original archive URLs as per-post `permalink:`
# overrides and rewriting internal cross-post links, image references, and
# known third-party CDN links (YouTube, Flickr) to https.
#
# Usage:
#   bundle install --with migration   # installs mysql2, redcloth, tzinfo
#   bundle exec ruby tools/migrate-mt-to-jekyll.rb
#
# Requires a local MySQL server with the MT database loaded, reachable with
# the credentials in ~/.my.cnf (a `[client]` section with `user`/`password`).
#
# After running, review MIGRATE_IMAGE_MAP (below) for the full list of
# referenced source-site images and download them into this repo at their
# listed paths (they're referenced as root-relative paths in the generated
# posts, so placing a file at the same path under the repo root is enough for
# Jekyll to serve it). Known-dead source URLs can be listed in
# tools/migrate-mt-dead-images.txt (one path per line) to leave them pointing
# at the original absolute URL instead of a local path that will never exist.
#
# BLOG_ID, SOURCE_DOMAIN, and SITE_TIMEZONE below are the only settings that
# should need changing to reuse this for a different Movable Type blog.

require 'mysql2'
require 'redcloth'
require 'tzinfo'
require 'yaml'
require 'set'

BLOG_ID = 1
SOURCE_DOMAIN = 'bloggy.com'
SITE_TIMEZONE = 'America/New_York'

REPO = File.expand_path('..', __dir__)
POSTS_DIR = File.join(REPO, '_posts')
DEAD_IMAGES_FILE = File.join(__dir__, 'migrate-mt-dead-images.txt')
IMAGE_MAP_OUTPUT = File.join(__dir__, 'migrate-mt-image-map.yml')

TZ = TZInfo::Timezone.get(SITE_TIMEZONE)
DEAD_IMAGES = File.exist?(DEAD_IMAGES_FILE) ? File.readlines(DEAD_IMAGES_FILE).map(&:chomp).to_set : Set.new

my_cnf = File.read(File.expand_path('~/.my.cnf'))
db_pass = my_cnf[/password="(.*)"/, 1]
client = Mysql2::Client.new(host: '127.0.0.1', username: 'root', password: db_pass, database: 'movable_type')

def offset_str(t)
  period = TZ.period_for_local(t, dst: false)
  secs = period.utc_total_offset
  sign = secs < 0 ? '-' : '+'
  secs = secs.abs
  format('%s%02d:%02d', sign, secs / 3600, (secs % 3600) / 60)
end

def slugify(basename)
  basename.gsub('_', '-')
end

def yaml_scalar(str)
  str.to_s.gsub('"', '\\"')
end

entries = client.query(<<~SQL, cache_rows: false).to_a
  SELECT entry_id, entry_title, entry_text, entry_text_more, entry_basename, entry_authored_on
  FROM mt_entry
  WHERE entry_blog_id = #{BLOG_ID} AND entry_status = 2 AND entry_class = 'entry'
  ORDER BY entry_authored_on
SQL

cat_stmt = client.prepare(<<~SQL)
  SELECT c.category_label, p.placement_is_primary, c.category_id
  FROM mt_placement p JOIN mt_category c ON c.category_id = p.placement_category_id
  WHERE p.placement_entry_id = ?
  ORDER BY p.placement_is_primary DESC, c.category_id ASC
SQL

# ---- Pass 1: build entry_id -> permalink and slug -> permalink maps for cross-post link resolution ----
id_to_permalink = {}
slug_to_permalink = {}
entries.each do |row|
  slug = slugify(row['entry_basename'].to_s)
  ym = row['entry_authored_on'].strftime('%Y/%m')
  permalink = "/#{ym}/#{slug}.html"
  id_to_permalink[row['entry_id']] = permalink
  slug_to_permalink["#{ym}/#{slug}"] = permalink
end

# ---- Pass 2: convert + rewrite links ----
image_map = {}
youtube_count = 0
flickr_count = 0
image_count = 0
id_link_count = 0
slug_link_count = 0
old_site_fallback_count = 0
written = 0
seen_filenames = {}

entries.each do |row|
  id = row['entry_id']
  title = row['entry_title'].to_s
  basename = row['entry_basename'].to_s
  authored = row['entry_authored_on']

  cats = cat_stmt.execute(id).to_a
  primary = cats.find { |c| c['placement_is_primary'] == 1 } || cats.first
  categories = primary ? [primary['category_label']] : []
  tags = cats.reject { |c| c.equal?(primary) }.map { |c| c['category_label'] }

  body_raw = [row['entry_text'], row['entry_text_more']].compact.reject(&:empty?).join("\n\n")
  # Known typos for the href attribute seen in hand-written HTML within Textile source.
  # Add more here if a future migration turns up other variants.
  body_raw = body_raw.gsub(' bref=', ' href=')
  body_raw = body_raw.gsub(' hrer=', ' href=')
  html = RedCloth.new(body_raw).to_html
  html = html.gsub('<a>', '') # bare <a> with no attributes: typo for </a>
  html = html.gsub(/<p>\s*<br\s*\/?>\s*<\/p>/i, '') # empty paragraph left by a standalone <br>

  # Unwrap links left empty/incomplete by the original author (e.g. "text": with
  # nothing after the colon in Textile), keeping the text but dropping the broken link.
  html = html.gsub(%r{<a href="(?:|https?://)">(.*?)</a>}im) { $1 }

  # Rewrite SOURCE_DOMAIN absolute image URLs. Known-dead ones (see
  # DEAD_IMAGES_FILE) are left as absolute (dead) URLs so html-proofer's
  # --disable-external skips them instead of flagging a broken internal link;
  # everything else becomes root-relative and is tracked for download.
  html = html.gsub(/(src|href)="https?:\/\/#{Regexp.escape(SOURCE_DOMAIN)}(\/[^"]*)"/i) do
    attr = $1
    path = $2
    if path =~ /\.(jpe?g|png|gif|bmp|webp|pdf|svg)(\?.*)?$/i
      if DEAD_IMAGES.include?(path)
        %(#{attr}="https://#{SOURCE_DOMAIN}#{path}")
      else
        image_map[path] = "https://#{SOURCE_DOMAIN}#{path}"
        image_count += 1
        %(#{attr}="#{path}")
      end
    else
      %(#{attr}="#{path}")
    end
  end

  # Track images already referenced via a relative path (Textile bang-image syntax,
  # or plain <img>/<a> markup) in either src= or href=, with or without a leading slash.
  html = html.gsub(/(src|href)="(\/?(?!\/)(?!https?:)[^"]*\.(?:jpe?g|png|gif|bmp|webp|pdf|svg))"/i) do
    attr = $1
    raw_path = $2
    path = raw_path.start_with?('/') ? raw_path : "/#{raw_path}"
    if DEAD_IMAGES.include?(path)
      %(#{attr}="https://#{SOURCE_DOMAIN}#{path}")
    else
      unless image_map.key?(path)
        image_map[path] = "https://#{SOURCE_DOMAIN}#{path}"
        image_count += 1
      end
      %(#{attr}="#{path}")
    end
  end

  # Rewrite YouTube http -> https
  html = html.gsub(/http:\/\/(www\.)?youtube\.com/i) do
    youtube_count += 1
    "https://#{$1}youtube.com"
  end
  html = html.gsub('http://youtu.be', 'https://youtu.be')

  # Rewrite Flickr http -> https (image CDN hosts + main site)
  html = html.gsub(/http:\/\/((?:www\.|static\.|farm\d+\.static\.)?flickr\.com)/i) do
    flickr_count += 1
    "https://#{$1}"
  end

  # --- Cross-post link resolution ---
  # 1. /mt/archives/NNNNNN.html (optionally with a #NNNNNN fragment) -> numeric entry ID
  html = html.gsub(%r{(href)="/mt/archives/0*(\d+)\.html(?:#0*\d+)?"}i) do
    attr = $1
    target_id = $2.to_i
    if id_to_permalink[target_id]
      id_link_count += 1
      %(#{attr}="#{id_to_permalink[target_id]}")
    else
      $~[0]
    end
  end

  # 2. /mt/archives/YYYY_MM.html#NNNNNN -> numeric entry ID via the fragment
  html = html.gsub(%r{(href)="/mt/archives/\d{4}_\d{2}\.html#0*(\d+)"}i) do
    attr = $1
    target_id = $2.to_i
    if id_to_permalink[target_id]
      id_link_count += 1
      %(#{attr}="#{id_to_permalink[target_id]}")
    else
      $~[0]
    end
  end

  # 3. /YYYY/MM/basename.html using underscores (old raw basename) instead of dashes.
  # Malformed links (e.g. trailing garbage after .html) naturally fail to match and are left as-is.
  html = html.gsub(%r{(href)="/(\d{4})/(\d{2})/([a-zA-Z0-9_-]+)\.html"}i) do
    attr = $1
    y = $2
    m = $3
    raw_slug = $4
    dashed = raw_slug.gsub('_', '-')
    key = "#{y}/#{m}/#{dashed}"
    if slug_to_permalink[key]
      slug_link_count += 1
      %(#{attr}="#{slug_to_permalink[key]}")
    else
      $~[0]
    end
  end

  # 4. Any remaining old-site-only resource links (non-post archives, galleries, mp3s,
  #    audio/video files, admin/utility URLs, bare top-level pages) that still resolve
  #    on the live legacy site -> absolute URL.
  html = html.gsub(%r{(href)="(/(?:mt/|gallery/|mp3/|about\.html|blog_links\.php)[^"]*)"}i) do
    attr = $1
    path = $2
    old_site_fallback_count += 1
    %(#{attr}="https://#{SOURCE_DOMAIN}#{path}")
  end
  html = html.gsub(%r{(src|href)="(/[^"]*\.(?:mov|3gp|swf))"}i) do
    attr = $1
    path = $2
    old_site_fallback_count += 1
    %(#{attr}="https://#{SOURCE_DOMAIN}#{path}")
  end
  html = html.gsub(%r{(href)="(/[a-zA-Z][a-zA-Z0-9_-]*\.html)"}i) do
    attr = $1
    path = $2
    old_site_fallback_count += 1
    %(#{attr}="https://#{SOURCE_DOMAIN}#{path}")
  end

  slug = slugify(basename)
  date_str = authored.strftime('%Y-%m-%d')
  offset = offset_str(authored)
  ym = authored.strftime('%Y/%m')
  permalink = "/#{ym}/#{slug}.html"

  filename = "#{date_str}-#{slug}.md"
  if seen_filenames[filename]
    STDERR.puts "WARN: duplicate filename #{filename} (entry #{id}, previous entry #{seen_filenames[filename]})"
  end
  seen_filenames[filename] = id

  fm_lines = []
  fm_lines << "title: \"#{yaml_scalar(title)}\""
  fm_lines << "date: #{authored.strftime('%Y-%m-%d %H:%M:%S')} #{offset}"
  fm_lines << "categories: [#{categories.map { |c| yaml_scalar(c) }.join(', ')}]" unless categories.empty?
  fm_lines << "tags: [#{tags.map { |c| yaml_scalar(c) }.join(', ')}]" unless tags.empty?
  fm_lines << "permalink: #{permalink}"

  content = "---\n#{fm_lines.join("\n")}\n---\n\n#{html.strip}\n"
  File.write(File.join(POSTS_DIR, filename), content)
  written += 1
end

puts "Entries written: #{written}"
puts "Distinct #{SOURCE_DOMAIN} images referenced: #{image_map.size} (#{image_count} occurrences)"
puts "YouTube http:// links rewritten: #{youtube_count}"
puts "Flickr http:// links rewritten: #{flickr_count}"
puts "Cross-post links resolved via numeric ID: #{id_link_count}"
puts "Cross-post links resolved via underscore/dash slug match: #{slug_link_count}"
puts "Old-site resource links pointed at legacy absolute URL: #{old_site_fallback_count}"
puts "Duplicate filenames: #{seen_filenames.size < written ? 'SEE WARNINGS ABOVE' : 0}"
puts "Image map written to #{IMAGE_MAP_OUTPUT} - download these into the repo at their listed paths."

File.write(IMAGE_MAP_OUTPUT, image_map.to_yaml)
