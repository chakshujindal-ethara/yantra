#!/usr/bin/env python3
"""Builds ../Yantra.html: every document, every diagram and the screen mockups in one
self-contained file that can be sent as an attachment. Run: python3 build_single.py"""
import html
import os
import re

import build  # the per-document builder in this folder

HERE = build.HERE
ROOT = build.ROOT
DOCS = ["01-understanding-yantra.md", "02-system-design.md", "03-user-flows.md", "04-tech-stack.md", "05-unified-plan.md"]

EXTRA_CSS = """
section.doc{padding-top:8px}
section.doc + section.doc{margin-top:96px;border-top:3px solid var(--line);padding-top:48px}
.doc-eyebrow{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--accent);font-weight:600;margin:0 0 10px}
nav.toc details{margin:2px 0}
nav.toc summary{cursor:pointer;list-style:none;color:var(--fg);font-size:14.5px;padding:7px 10px;border-radius:8px;font-weight:600}
nav.toc summary::-webkit-details-marker{display:none}
nav.toc summary:hover{background:var(--surface2)}
nav.toc details[open] summary{background:var(--accent-soft)}
.screens{border:1px solid var(--line);border-radius:14px;overflow:hidden;background:var(--surface);margin:8px 0 28px;width:min(1240px,calc(100vw - 396px));margin-left:calc((min(100%,880px) - min(1240px,calc(100vw - 396px))) / 2)}
.screens iframe{display:block;width:100%;height:1000px;border:0;background:var(--bg)}
@media (max-width:980px){.screens{width:100%;margin-left:0}.screens iframe{height:860px}}
.intro{font-size:19px;line-height:1.6;color:var(--muted);max-width:66ch;margin:0 0 28px}
"""


def convert(doc, prefix):
    body = build.md_to_html(os.path.join(ROOT, doc))
    toc = []

    def head(m):
        level, text = m.group(1), m.group(2)
        sid = prefix + "-" + build.slug(text)
        toc.append((level, re.sub(r"<[^>]+>", "", text), sid))
        return f'<h{level} id="{sid}">{text}</h{level}>'
    body = re.sub(r"<h([23])>(.*?)</h\1>", head, body)
    title_m = re.search(r"<h1>(.*?)</h1>", body)
    title = re.sub(r"<[^>]+>", "", title_m.group(1)) if title_m else doc
    body = re.sub(r"<h1>.*?</h1>", "", body, count=1, flags=re.S)

    def img(m):
        srcp, alt = m.group(1), m.group(2)
        p = os.path.join(ROOT, srcp)
        if srcp.endswith(".svg") and os.path.exists(p):
            svg = re.sub(r"<\?xml[^>]*\?>", "", open(p).read())
            return f'<figure class="diagram">{svg}<figcaption>{html.escape(alt)}</figcaption></figure>'
        return m.group(0)
    body = re.sub(r'<img src="([^"]+)" alt="([^"]*)"\s*/?>', img, body)
    body = re.sub(r"<p>(<figure.*?</figure>)</p>", r"\1", body, flags=re.S)
    body = body.replace("<table>", '<div class="tablewrap"><table>').replace("</table>", "</table></div>")
    body = re.sub(r'<h2 id="[^"]*-contents">Contents</h2>\s*<ol>.*?</ol>', "", body, flags=re.S)
    # cross-document links become in-page anchors; file references become plain text
    for i, d in enumerate(DOCS, 1):
        body = body.replace(f'href="{d}"', f'href="#doc-{i:02d}"')
    body = body.replace('href="mockups/unified-plan.html"', 'href="#doc-06"').replace('href="mockups/WALKTHROUGH.md"', 'href="#d6-walkthrough"')
    body = re.sub(r'<a href="(mockups/[^"]+|diagrams/[^"]*)">(.*?)</a>', r"\2", body)
    return title, body, [(l, t, s) for l, t, s in toc if l == "2" and not s.endswith("-contents")]


def main():
    mock = open(os.path.join(ROOT, "mockups", "unified-plan.html")).read()
    walk_title, walk_body, _ = convert("mockups/WALKTHROUGH.md", "walk")
    sections, nav = [], []
    for i, d in enumerate(DOCS, 1):
        title, body, toc = convert(d, f"d{i}")
        sid = f"doc-{i:02d}"
        sections.append(f'<section class="doc" id="{sid}"><p class="doc-eyebrow">Part {i} of 6</p><h1>{html.escape(title)}</h1>{body}</section>')
        links = "".join(f'<a class="h2" href="#{s}">{html.escape(t)}</a>' for l, t, s in toc)
        nav.append(f'<details{" open" if i == 1 else ""}><summary>{i}. {html.escape(title)}</summary>{links}</details>')
    sections.append(
        '<section class="doc" id="doc-06"><p class="doc-eyebrow">Part 6 of 6</p><h1>The screens</h1>'
        '<p class="intro">One mocked screen per journey, in the order of the loop. Use the list on the left of the frame or the arrow keys inside it. Figures on every screen are examples.</p>'
        f'<div class="screens"><iframe title="Yantra screen mockups" srcdoc="{html.escape(mock, quote=True)}"></iframe></div>'
        f'<h2 id="d6-walkthrough">What to test on each screen</h2>{walk_body}</section>')
    nav.append('<details><summary>6. The screens</summary><a class="h2" href="#doc-06">The mockups</a><a class="h2" href="#d6-walkthrough">What to test</a></details>')
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Yantra</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:ital,wght@0,400;0,500;0,600;0,700;1,400&family=DM+Mono:wght@400;500&display=swap">
<style>{build.CSS}{EXTRA_CSS}</style></head>
<body id="top"><div class="shell">
<nav class="toc" aria-label="Contents">
  <div class="brand"><div class="mark">Y</div><div><b>Yantra</b><small>plan, design and screens, 2 November 2026</small></div></div>
  <button type="button" class="theme" id="theme" aria-label="Toggle light or dark theme"></button>
  <div class="set">Contents</div>{"".join(nav)}
</nav>
<main><article>
<p class="doc-eyebrow">Yantra</p>
<h1>Trusted supply and verified production of AI training work</h1>
<p class="intro">Everything about Yantra in one file: a plain-language guide, the system design, the user flows, the technology, the plan, and the screens. Diagrams are drawn to be edited in draw.io; the editable files travel with the full folder. The Yantra repository documents are the point of truth; where this pack proposes a change it says so.</p>
<div class="tablewrap"><table><thead><tr><th>Part</th><th>Read it for</th></tr></thead><tbody>
<tr><td><a href="#doc-01">1. Understanding Yantra</a></td><td>what it is, the words, the people, the loop with real numbers, how it is built, the questions you will be asked</td></tr>
<tr><td><a href="#doc-02">2. System design</a></td><td>context, containers, repository, deployment, data model, events, sequences, API, security, scale, operations</td></tr>
<tr><td><a href="#doc-03">3. User flows</a></td><td>the worker, the reviewer, ops and the client, finance, the Stage 3 factory</td></tr>
<tr><td><a href="#doc-04">4. Tech stack</a></td><td>every technology, its role, why, and what was not chosen</td></tr>
<tr><td><a href="#doc-05">5. The unified plan</a></td><td>business, principles, stages and gates, decisions, measures, risks, alternatives</td></tr>
<tr><td><a href="#doc-06">6. The screens</a></td><td>one mocked screen per journey, and what to test on each</td></tr>
</tbody></table></div>
{"".join(sections)}
<p class="foot">Yantra, 2 November 2026. Evidence tags: [D] disclosed by the company named, [R] reported by press or analysts, [E] estimate, [L] read from the company's own repositories.</p>
</article></main></div>
<script>{build.JS}</script>
</body></html>
"""
    out = os.path.join(ROOT, "Yantra.html")
    with open(out, "w") as f:
        f.write(page)
    print("built", out, len(page))


if __name__ == "__main__":
    main()
