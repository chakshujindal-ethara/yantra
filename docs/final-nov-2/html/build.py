#!/usr/bin/env python3
"""Builds a self-contained HTML page for each Markdown document in the parent folder.
Diagrams are inlined as SVG, so one file can be shared on its own. Run: python3 build.py
Needs node (npx marked) on the PATH."""
import html
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DOCS = ["01-understanding-yantra.md", "02-system-design.md", "03-user-flows.md", "04-tech-stack.md", "05-unified-plan.md"]

CSS = """
:root{--bg:#f8f9fa;--surface:#ffffff;--surface2:#f3f3f5;--fg:#030213;--muted:#717182;--line:#e0e0e4;--accent:#b800b8;--accent-soft:#fbdaf7;--ring:#b800b8;--code:#f3f3f5;
 --body:"Plus Jakarta Sans",ui-sans-serif,system-ui,sans-serif;--mono:"DM Mono",ui-monospace,SFMono-Regular,Menlo,monospace}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#0a0a0d;--surface:#18181c;--surface2:#222228;--fg:#ececf0;--muted:#a0a0ac;--line:#2f2f35;--accent:#c552bc;--accent-soft:#2a1427;--ring:#d66ecd;--code:#222228;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#0a0a0d;--surface:#18181c;--surface2:#222228;--fg:#ececf0;--muted:#a0a0ac;--line:#2f2f35;--accent:#c552bc;--accent-soft:#2a1427;--ring:#d66ecd;--code:#222228;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.65 var(--body)}
.shell{display:grid;grid-template-columns:300px minmax(0,1fr);min-height:100vh}
nav.toc{position:sticky;top:0;align-self:start;height:100vh;overflow:auto;border-right:1px solid var(--line);background:var(--surface);padding:28px 20px 40px max(20px,env(safe-area-inset-left,0px))}
nav.toc .brand{display:flex;align-items:center;gap:12px;margin-bottom:8px}
nav.toc .mark{width:34px;height:34px;border-radius:9px;background:var(--accent);color:#fff;display:grid;place-items:center;font-weight:700}
nav.toc .brand b{display:block;font-size:16px}
nav.toc .brand small{display:block;color:var(--muted);font-size:12.5px}
nav.toc .set{margin:18px 0 8px;font-size:11.5px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);font-weight:600}
nav.toc a{display:block;color:var(--fg);text-decoration:none;font-size:14.5px;padding:7px 10px;border-radius:8px;line-height:1.4}
nav.toc a:hover{background:var(--surface2)}
nav.toc a.h3{padding-left:24px;color:var(--muted);font-size:13.5px}
nav.toc a.doc{color:var(--muted)}
nav.toc a.doc.on{background:var(--accent-soft);color:var(--fg);font-weight:600}
.theme{margin:14px 0 4px;display:inline-flex;align-items:center;gap:8px;border:1px solid var(--line);background:var(--surface2);color:var(--fg);font:500 13.5px var(--body);padding:8px 12px;border-radius:8px;cursor:pointer}
.theme:focus-visible,nav.toc a:focus-visible{outline:2px solid var(--ring);outline-offset:2px}
main{padding:56px max(24px,env(safe-area-inset-right,0px)) 96px max(24px,env(safe-area-inset-left,0px));min-width:0}
article{max-width:880px;margin:0 auto}
article h1{font-size:40px;line-height:1.15;letter-spacing:-.01em;margin:0 0 24px;text-wrap:balance}
article h2{font-size:28px;line-height:1.25;margin:64px 0 20px;padding-top:24px;border-top:1px solid var(--line);text-wrap:balance}
article h3{font-size:21px;margin:40px 0 14px;text-wrap:balance}
article p{margin:0 0 18px;max-width:72ch}
article ul,article ol{padding-left:26px;margin:0 0 20px}
article li{margin:6px 0;max-width:70ch}
article li p{margin:0}
article a{color:var(--accent)}
article strong{font-weight:600}
article hr{display:none}
article code{font:14.5px var(--mono);background:var(--code);padding:2px 6px;border-radius:5px}
article pre{background:var(--code);border:1px solid var(--line);border-radius:12px;padding:20px 22px;overflow:auto;font:14px/1.55 var(--mono);margin:0 0 24px}
article pre code{background:none;padding:0;font-size:inherit}
.tablewrap{overflow-x:auto;margin:0 0 28px;border:1px solid var(--line);border-radius:12px;background:var(--surface)}
article table{border-collapse:collapse;width:100%;font-size:15px;line-height:1.5}
article th{text-align:left;font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);background:var(--surface2);padding:14px 16px;border-bottom:1px solid var(--line)}
article td{padding:14px 16px;border-bottom:1px solid var(--line);vertical-align:top}
article tr:last-child td{border-bottom:0}
article td:first-child{font-weight:600;white-space:normal;min-width:140px}
figure.diagram{margin:8px 0 36px;background:#ffffff;border:1px solid var(--line);border-radius:14px;padding:12px;overflow-x:auto}
figure.diagram svg{display:block;max-width:100%;height:auto}
figure.diagram figcaption{font-size:13.5px;color:var(--muted);padding:10px 8px 2px}
blockquote{margin:0 0 20px;padding:14px 20px;border-left:3px solid var(--accent);background:var(--surface2);border-radius:0 10px 10px 0}
.foot{margin-top:72px;color:var(--muted);font-size:14px;border-top:1px solid var(--line);padding-top:16px}
@media (max-width:980px){.shell{grid-template-columns:1fr}nav.toc{position:static;height:auto;border-right:0;border-bottom:1px solid var(--line)}main{padding-top:32px}article h1{font-size:32px}article h2{font-size:24px;margin-top:44px}}
"""

JS = """
(function(){var r=document.documentElement,b=document.getElementById('theme');
function cur(){var t=r.getAttribute('data-theme');if(t)return t;return (window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches)?'dark':'light';}
function paint(){b.textContent=cur()==='dark'?'\\u263C Light mode':'\\u263E Dark mode';}
try{var s=localStorage.getItem('etp.theme');if(s==='dark'||s==='light')r.setAttribute('data-theme',s);}catch(e){}
b.addEventListener('click',function(){var n=cur()==='dark'?'light':'dark';r.setAttribute('data-theme',n);try{localStorage.setItem('etp.theme',n);}catch(e){}paint();});paint();
})();
"""


def slug(t):
    t = re.sub(r"<[^>]+>", "", t)
    t = html.unescape(t).lower()
    t = re.sub(r"[^a-z0-9]+", "-", t).strip("-")
    return t or "s"


def md_to_html(path):
    out = subprocess.run(["npx", "-y", "marked", "--gfm", "-i", path], capture_output=True, text=True, check=True)
    return out.stdout


def build(doc):
    src = os.path.join(ROOT, doc)
    body = md_to_html(src)
    # headings with ids, and the table of contents
    toc = []
    def head(m):
        level, text = m.group(1), m.group(2)
        sid = slug(text)
        toc.append((level, re.sub(r"<[^>]+>", "", text), sid))
        return f'<h{level} id="{sid}">{text}</h{level}>'
    body = re.sub(r"<h([23])>(.*?)</h\1>", head, body)
    title_m = re.search(r"<h1>(.*?)</h1>", body)
    title = re.sub(r"<[^>]+>", "", title_m.group(1)) if title_m else doc
    # inline diagrams
    def img(m):
        srcp, alt = m.group(1), m.group(2)
        p = os.path.join(ROOT, srcp)
        if srcp.endswith(".svg") and os.path.exists(p):
            svg = open(p).read()
            svg = re.sub(r"<\?xml[^>]*\?>", "", svg)
            return f'<figure class="diagram">{svg}<figcaption>{html.escape(alt)}</figcaption></figure>'
        return m.group(0)
    body = re.sub(r'<img src="([^"]+)" alt="([^"]*)"\s*/?>', img, body)
    body = body.replace('href="html/', 'href="')
    body = re.sub(r"<p>(<figure.*?</figure>)</p>", r"\1", body, flags=re.S)
    body = body.replace("<table>", '<div class="tablewrap"><table>').replace("</table>", "</table></div>")
    # links between documents point at the html versions
    body = re.sub(r'href="(\d\d-[a-z-]+)\.md"', r'href="\1.html"', body)
    body = re.sub(r'href="(mockups/[^"]+|diagrams/[^"]*)"', r'href="../\1"', body)
    # drop the markdown "Contents" list: the sidebar replaces it
    body = re.sub(r'<h2 id="contents">Contents</h2>\s*<ol>.*?</ol>', "", body, flags=re.S)
    docs_nav = "".join(
        f'<a class="doc{" on" if d == doc else ""}" href="{d[:-3]}.html">{html.escape(DOC_TITLES[d])}</a>' for d in DOCS)
    toc_html = "".join(f'<a class="h{l}" href="#{s}">{html.escape(t)}</a>' for l, t, s in toc if l == "2" and s != "contents")
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>{html.escape(title)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:ital,wght@0,400;0,500;0,600;0,700;1,400&family=DM+Mono:wght@400;500&display=swap">
<style>{CSS}</style></head>
<body><div class="shell">
<nav class="toc" aria-label="Contents">
  <div class="brand"><div class="mark">Y</div><div><b>Yantra</b><small>plan, design and screens, 2 November 2026</small></div></div>
  <button type="button" class="theme" id="theme" aria-label="Toggle light or dark theme"></button>
  <div class="set">Documents</div>{docs_nav}
  <div class="set">On this page</div>{toc_html}
</nav>
<main><article>
{body}
<p class="foot">Yantra, 2 November 2026. Every diagram can be edited in draw.io. Evidence tags: [D] disclosed by the company named, [R] reported by press or analysts, [E] estimate, [L] read from the company's own repositories.</p>
</article></main></div>
<script>{JS}</script>
</body></html>
"""
    out = os.path.join(HERE, doc[:-3] + ".html")
    with open(out, "w") as f:
        f.write(page)
    print("built", out, len(page))


DOC_TITLES = {"01-understanding-yantra.md": "Understanding Yantra", "02-system-design.md": "System design",
              "03-user-flows.md": "User flows", "04-tech-stack.md": "Tech stack", "05-unified-plan.md": "The unified plan"}

if __name__ == "__main__":
    for d in DOCS:
        build(d)
