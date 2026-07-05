# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A personal Jekyll blog ("bloggy", art/culture/politics) built on the [Chirpy starter](https://github.com/cotes2020/chirpy-starter). The theme comes from the `jekyll-theme-chirpy` gem (~7.5) — layouts, includes, and Sass live inside the gem, not this repo. To inspect them: `bundle info --path jekyll-theme-chirpy`.

Ruby 3.3.3 is pinned via `mise.toml`.

## Commands

```bash
bundle install                    # install dependencies
bash tools/run.sh                 # dev server with live reload (bundle exec jekyll s -l)
bash tools/run.sh -p              # serve in production mode
bash tools/test.sh                # test: production build + html-proofer link checking
```

There are no unit tests; `tools/test.sh` is the whole test suite (it rebuilds `_site` from scratch and validates internal links/HTML).

## Structure

- `_config.yml` — all site configuration (title, author, social links, analytics, comments, PWA). Most customization happens here rather than in code.
- `_posts/` — blog posts, named `YYYY-MM-DD-title.md`. Chirpy frontmatter conventions apply (`categories`, `tags`, etc.).
- `_tabs/` — sidebar pages (About, Archives, Categories, Tags), ordered by `order` frontmatter.
- `_plugins/posts-lastmod-hook.rb` — sets `last_modified_at` on posts from git log; a post's modification date only updates once it has more than one commit touching it.
- `_data/contact.yml`, `_data/share.yml` — which contact icons and share buttons appear.
- `assets/lib` — git submodule (chirpy-static-assets); run `git submodule update --init` after a fresh clone or the site will be missing JS/CSS assets.

## Notes

- The GitHub Actions deploy workflow was intentionally removed; there is no CI in this repo.
- `_site/` and `.jekyll-cache/` are build output — never edit them.
