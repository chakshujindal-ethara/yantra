#!/usr/bin/env python3
"""Builds the standalone pages that sit next to Yantra.html: the comparison with the repository
and the enhanced plan. Each is one self-contained file. Run: python3 build_standalone.py"""
import html
import os

import build
import build_single

ROOT = build.ROOT
PAGES = [
    ("06-what-is-new.md", "What-is-new.html", "Yantra: what is new", "the repository and this pack, 2 November 2026",
     "The repository documents named on this page are the Yantra repository's own; everything else is this pack's. Each proposal stays a proposal until leadership accepts it."),
    ("07-enhanced-plan.md", "Enhanced-plan.html", "Yantra: the enhanced plan", "a second option next to the unified plan, 2 November 2026",
     "Evidence tags: [D] disclosed by the company named, [R] reported, [E] estimate, [L] read from the company's own repositories, (assumption) to confirm. Every diagram can be edited in draw.io."),
]


def page(doc, out_name, title_tag, subtitle, foot):
    title, body, toc = build_single.convert(doc, "c")
    nav = "".join(f'<a class="h2" href="#{s}">{html.escape(t)}</a>' for _, t, s in toc)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>{html.escape(title_tag)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:ital,wght@0,400;0,500;0,600;0,700;1,400&family=DM+Mono:wght@400;500&display=swap">
<style>{build.CSS}{build_single.EXTRA_CSS}</style></head>
<body id="top"><div class="shell">
<nav class="toc" aria-label="Contents">
  <div class="brand"><div class="mark">Y</div><div><b>Yantra</b><small>{html.escape(subtitle)}</small></div></div>
  <button type="button" class="theme" id="theme" aria-label="Toggle light or dark theme"></button>
  <div class="set">Contents</div>{nav}
</nav>
<main><article>
<p class="doc-eyebrow">Yantra</p>
<h1>{html.escape(title)}</h1>
{body}
<p class="foot">Yantra, 2 November 2026. {html.escape(foot)}</p>
</article></main></div>
<script>{build.JS}</script>
</body></html>
"""


def main():
    for doc, out_name, title_tag, subtitle, foot in PAGES:
        out = os.path.join(ROOT, out_name)
        with open(out, "w") as f:
            f.write(page(doc, out_name, title_tag, subtitle, foot))
        print("built", out, os.path.getsize(out))


if __name__ == "__main__":
    main()
