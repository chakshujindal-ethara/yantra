#!/usr/bin/env python3
"""Builds every diagram in this folder twice from one model: an editable .drawio file
(open in diagrams.net or the draw.io desktop app) and a static .svg (embedded in the
Markdown and HTML). Run: python3 build_diagrams.py

Layout is explicit (x, y in pixels) so the two outputs match. Keep diagrams on a
40px grid; keep labels short; one idea per diagram."""
import html
import math
import os
import textwrap

OUT = os.path.dirname(os.path.abspath(__file__))

# Ethara portal palette (light), used for both outputs.
KINDS = {
    "app":      dict(fill="#FBDAF7", stroke="#B800B8", text="#030213"),
    "service":  dict(fill="#EFF6FF", stroke="#1D4ED8", text="#030213"),
    "odoo":     dict(fill="#ECFDF5", stroke="#047857", text="#030213"),
    "infra":    dict(fill="#F3F3F5", stroke="#717182", text="#030213"),
    "external": dict(fill="#FFF7ED", stroke="#C2410C", text="#030213", dashed=True),
    "later":    dict(fill="#FFFFFF", stroke="#9CA3AF", text="#717182", dashed=True),
    "actor":    dict(fill="#FFFFFF", stroke="#030213", text="#030213", width=2),
    "step":     dict(fill="#FFFFFF", stroke="#4B4B57", text="#030213"),
    "money":    dict(fill="#FFF7ED", stroke="#C2410C", text="#030213"),
    "gate":     dict(fill="#FEF2F2", stroke="#B91C1C", text="#030213"),
    "decision": dict(fill="#FFFFFF", stroke="#4B4B57", text="#030213", shape="rhombus"),
    "start":    dict(fill="#030213", stroke="#030213", text="#FFFFFF", shape="pill"),
    "end":      dict(fill="#047857", stroke="#047857", text="#FFFFFF", shape="pill"),
    "entity":   dict(fill="#FFFFFF", stroke="#1D4ED8", text="#030213", shape="entity"),
    "subject":  dict(fill="#F3F3F5", stroke="#717182", text="#030213", shape="pill"),
    "note":     dict(fill="none", stroke="none", text="#717182", shape="text"),
}
FONT = "Helvetica Neue, Helvetica, Arial, sans-serif"
MONO = "Menlo, Consolas, monospace"


class D:
    def __init__(self, name, title, subtitle="", legend=None):
        self.name, self.title, self.subtitle = name, title, subtitle
        self.legend = legend or []
        self.nodes, self.edges, self.lanes = [], [], []

    def lane(self, x, y, w, h, label, fill="#FAFAFB"):
        self.lanes.append(dict(x=x, y=y, w=w, h=h, label=label, fill=fill))

    def n(self, id, x, y, w, h, label, sub="", kind="service", tech=""):
        self.nodes.append(dict(id=id, x=x, y=y, w=w, h=h, label=label, sub=sub, kind=kind, tech=tech))
        return id

    def e(self, a, b, label="", points=None, dashed=False, both=False, color="#4B4B57", raw=False, seg=None, arrow=True, above=False):
        self.edges.append(dict(a=a, b=b, label=label, points=points or [], dashed=dashed, both=both, color=color, raw=raw, seg=seg, arrow=arrow, above=above))

    # ---------- geometry helpers ----------
    def node(self, id):
        return next(n for n in self.nodes if n["id"] == id)

    def extent(self):
        xs = [n["x"] for n in self.nodes] + [l["x"] for l in self.lanes]
        ys = [n["y"] for n in self.nodes] + [l["y"] for l in self.lanes]
        xe = [n["x"] + n["w"] for n in self.nodes] + [l["x"] + l["w"] for l in self.lanes]
        ye = [n["y"] + n["h"] for n in self.nodes] + [l["y"] + l["h"] for l in self.lanes]
        for e in self.edges:
            for px, py in e["points"]:
                xs.append(px); ys.append(py); xe.append(px); ye.append(py)
        return min(xs), min(ys), max(xe), max(ye)

    def anchor(self, n, towards):
        """Point on the border of n facing the point `towards`."""
        cx, cy = n["x"] + n["w"] / 2, n["y"] + n["h"] / 2
        dx, dy = towards[0] - cx, towards[1] - cy
        py = min(max(towards[1], n["y"] + 14), n["y"] + n["h"] - 14)
        px = min(max(towards[0], n["x"] + 14), n["x"] + n["w"] - 14)
        if abs(dx) * n["h"] >= abs(dy) * n["w"]:
            return (n["x"] + n["w"], py) if dx > 0 else (n["x"], py)
        return (px, n["y"] + n["h"]) if dy > 0 else (px, n["y"])

    def route(self, e):
        if e.get("raw"):
            return list(e["points"])
        a, b = self.node(e["a"]), self.node(e["b"])
        ca = (a["x"] + a["w"] / 2, a["y"] + a["h"] / 2)
        cb = (b["x"] + b["w"] / 2, b["y"] + b["h"] / 2)
        if e["points"]:
            p0 = self.anchor(a, e["points"][0])
            p1 = self.anchor(b, e["points"][-1])
            return [p0] + list(e["points"]) + [p1]
        p0, p1 = self.anchor(a, cb), self.anchor(b, ca)
        if abs(p0[0] - p1[0]) < 1 or abs(p0[1] - p1[1]) < 1:
            return [p0, p1]
        # orthogonal: leave horizontally if the anchor is on a side, else vertically
        if p0[0] in (a["x"], a["x"] + a["w"]):
            mx = (p0[0] + p1[0]) / 2
            return [p0, (mx, p0[1]), (mx, p1[1]), p1]
        my = (p0[1] + p1[1]) / 2
        return [p0, (p0[0], my), (p1[0], my), p1]


# ---------- SVG ----------
def wrap(text, width, size):
    cw = size * 0.55
    maxc = max(4, int(width / cw))
    lines = []
    for para in text.split("\n"):
        lines += textwrap.wrap(para, maxc) or [""]
    return lines


def svg_text(x, y, lines, size, color, weight="normal", anchor="middle", family=FONT, lh=1.25):
    out = []
    total = (len(lines) - 1) * size * lh
    y0 = y - total / 2
    for i, line in enumerate(lines):
        out.append(f'<text x="{x:.1f}" y="{y0 + i * size * lh:.1f}" font-family="{family}" font-size="{size}" '
                   f'font-weight="{weight}" fill="{color}" text-anchor="{anchor}" dominant-baseline="middle">{html.escape(line)}</text>')
    return "\n".join(out)


def to_svg(d):
    x0, y0, x1, y1 = d.extent()
    M = 40
    header = 60 if d.subtitle else 44
    legend_h = 34 if d.legend else 0
    W, H = (x1 - x0) + 2 * M, (y1 - y0) + 2 * M + header + legend_h
    ox, oy = M - x0, M - y0 + header
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.0f}" height="{H:.0f}" viewBox="0 0 {W:.0f} {H:.0f}" font-family="{FONT}">',
         '<defs><marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">'
         '<path d="M0,0 L10,5 L0,10 z" fill="#4B4B57"/></marker></defs>',
         f'<rect x="0" y="0" width="{W:.0f}" height="{H:.0f}" rx="12" fill="#FFFFFF" stroke="#E0E0E4"/>',
         svg_text(M, 28, [d.title], 17, "#030213", "bold", "start")]
    if d.subtitle:
        o.append(svg_text(M, 50, [d.subtitle], 12.5, "#717182", "normal", "start"))
    for l in d.lanes:
        o.append(f'<rect x="{l["x"] + ox}" y="{l["y"] + oy}" width="{l["w"]}" height="{l["h"]}" rx="10" fill="{l["fill"]}" stroke="#D8D8DE" stroke-dasharray="4 3"/>')
        o.append(svg_text(l["x"] + ox + 12, l["y"] + oy + 16, [l["label"].upper()], 11, "#717182", "bold", "start"))
    for n in d.nodes:
        k = KINDS[n["kind"]]
        x, y, w, h = n["x"] + ox, n["y"] + oy, n["w"], n["h"]
        dash = ' stroke-dasharray="6 4"' if k.get("dashed") else ""
        sw = k.get("width", 1.5)
        shape = k.get("shape", "rect")
        if shape == "rhombus":
            o.append(f'<polygon points="{x + w / 2},{y} {x + w},{y + h / 2} {x + w / 2},{y + h} {x},{y + h / 2}" fill="{k["fill"]}" stroke="{k["stroke"]}" stroke-width="{sw}"/>')
        elif shape == "pill":
            o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{h / 2}" fill="{k["fill"]}" stroke="{k["stroke"]}" stroke-width="{sw}"{dash}/>')
        elif shape == "entity":
            o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{k["fill"]}" stroke="{k["stroke"]}" stroke-width="{sw}"/>')
            o.append(f'<rect x="{x}" y="{y}" width="{w}" height="28" rx="6" fill="#EFF6FF" stroke="{k["stroke"]}" stroke-width="{sw}"/>')
            o.append(f'<rect x="{x}" y="{y + 20}" width="{w}" height="8" fill="#EFF6FF"/>')
            o.append(f'<line x1="{x}" y1="{y + 28}" x2="{x + w}" y2="{y + 28}" stroke="{k["stroke"]}" stroke-width="{sw}"/>')
        elif shape == "text":
            pass
        else:
            o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{k["fill"]}" stroke="{k["stroke"]}" stroke-width="{sw}"{dash}/>')
        if shape == "entity":
            o.append(svg_text(x + w / 2, y + 14, [n["label"]], 12.5, k["text"], "bold"))
            lines = n["sub"].split("\n")
            for i, line in enumerate(lines):
                o.append(svg_text(x + 10, y + 42 + i * 15, [line], 11, "#030213", "normal", "start", MONO))
            continue
        if shape == "text":
            paras = n["label"].split("\n")
            if len(paras) > 1:
                o.append(svg_text(x, y + 12, [paras[0]], 12.5, "#030213", "bold", "start"))
                o.append(svg_text(x, y + 30, wrap(paras[1], w, 11), 11, "#717182", "normal", "start"))
            else:
                o.append(svg_text(x, y + h / 2, wrap(n["label"], w, 11.5), 11.5, k["text"], "normal", "start"))
            continue
        pad = 60 if shape == "rhombus" else 16
        label_lines = wrap(n["label"], w - pad, 12.5)
        sub_lines = wrap(n["sub"], w - pad, 11) if n["sub"] else []
        tech_lines = [n["tech"]] if n["tech"] else []
        block = len(label_lines) * 12.5 * 1.25 + (len(sub_lines) * 11 * 1.25 + 4 if sub_lines else 0) + (14 if tech_lines else 0)
        cy = y + h / 2 - block / 2 + 12.5 * 1.25 / 2 + len(label_lines) * 12.5 * 1.25 / 2 - 12.5 * 1.25 / 2
        yy = y + h / 2 - block / 2
        yy += len(label_lines) * 12.5 * 1.25 / 2
        o.append(svg_text(x + w / 2, yy, label_lines, 12.5, k["text"], "bold"))
        yy += len(label_lines) * 12.5 * 1.25 / 2 + 4
        if sub_lines:
            yy += len(sub_lines) * 11 * 1.25 / 2
            o.append(svg_text(x + w / 2, yy, sub_lines, 11, "#717182" if n["kind"] not in ("start", "end") else "#FFFFFF"))
            yy += len(sub_lines) * 11 * 1.25 / 2
        if tech_lines:
            o.append(svg_text(x + w / 2, yy + 9, tech_lines, 10, "#717182", "normal", "middle", MONO))
    for e in d.edges:
        pts = [(px + ox, py + oy) for px, py in d.route(e)]
        path = " ".join(f'{"M" if i == 0 else "L"}{px:.1f},{py:.1f}' for i, (px, py) in enumerate(pts))
        dash = ' stroke-dasharray="6 4"' if e["dashed"] else ""
        ms = ' marker-start="url(#arr)"' if e["both"] else ""
        me = ' marker-end="url(#arr)"' if e.get("arrow", True) else ""
        o.append(f'<path d="{path}" fill="none" stroke="{e["color"]}" stroke-width="1.5"{me}{ms}{dash}/>')
        if e["label"]:
            segs = list(zip(pts, pts[1:]))
            if e.get("seg") is not None:
                (ax, ay), (bx, by) = segs[e["seg"]]
                best = ((ax + bx) / 2, (ay + by) / 2)
            else:
                best, bl = None, -1
                for (ax, ay), (bx, by) in segs:
                    L = math.hypot(bx - ax, by - ay)
                    if L > bl:
                        bl, best = L, ((ax + bx) / 2, (ay + by) / 2)
            lines = wrap(e["label"], 220 if e.get("above") else 160, 11)
            if e.get("above"):
                o.append(svg_text(best[0], best[1] - 9 - (len(lines) - 1) * 7, lines, 11, "#4B4B57"))
            else:
                tw = max(len(s) for s in lines) * 11 * 0.55 + 10
                th = len(lines) * 14 + 4
                o.append(f'<rect x="{best[0] - tw / 2:.1f}" y="{best[1] - th / 2:.1f}" width="{tw:.1f}" height="{th:.1f}" rx="4" fill="#FFFFFF" opacity="0.95"/>')
                o.append(svg_text(best[0], best[1], lines, 11, "#4B4B57"))
    if d.legend:
        lx = M
        ly = H - M / 2 - 10
        for kind, label in d.legend:
            k = KINDS[kind]
            dash = ' stroke-dasharray="6 4"' if k.get("dashed") else ""
            o.append(f'<rect x="{lx}" y="{ly - 7}" width="22" height="14" rx="4" fill="{k["fill"]}" stroke="{k["stroke"]}" stroke-width="1.5"{dash}/>')
            o.append(svg_text(lx + 28, ly, [label], 11, "#4B4B57", "normal", "start"))
            lx += 28 + len(label) * 11 * 0.55 + 24
    o.append("</svg>")
    return "\n".join(o)


# ---------- draw.io ----------
def drawio_style(n):
    k = KINDS[n["kind"]]
    shape = k.get("shape", "rect")
    base = f'whiteSpace=wrap;html=1;fillColor={k["fill"]};strokeColor={k["stroke"]};fontColor={k["text"]};fontFamily=Helvetica;fontSize=12;strokeWidth={k.get("width", 1.5)};'
    if k.get("dashed"):
        base += "dashed=1;"
    if shape == "rhombus":
        return "rhombus;" + base
    if shape == "pill":
        return "rounded=1;arcSize=50;" + base
    if shape == "entity":
        return "swimlane;fontStyle=1;childLayout=stackLayout;horizontal=1;startSize=28;horizontalStack=0;resizeParent=1;resizeParentMax=0;resizeLast=0;collapsible=0;marginBottom=0;" + base
    if shape == "text":
        return f"text;html=1;align=left;verticalAlign=middle;fontColor={k['text']};fontSize=11;whiteSpace=wrap;"
    return "rounded=1;" + base


def to_drawio(d):
    o = ['<mxfile host="app.diagrams.net" agent="yantra final-nov-2 build_diagrams.py" version="24.0.0">',
         f'  <diagram id="{d.name}" name="{html.escape(d.title)}">',
         '    <mxGraphModel dx="1400" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="1600" pageHeight="1000" math="0" shadow="0">',
         '      <root>', '        <mxCell id="0"/>', '        <mxCell id="1" parent="0"/>']
    o.append(f'        <mxCell id="title" value="{html.escape(d.title)}" style="text;html=1;align=left;verticalAlign=middle;fontSize=16;fontStyle=1;fontFamily=Helvetica;" vertex="1" parent="1"><mxGeometry x="0" y="-60" width="900" height="30" as="geometry"/></mxCell>')
    if d.subtitle:
        o.append(f'        <mxCell id="subtitle" value="{html.escape(d.subtitle)}" style="text;html=1;align=left;verticalAlign=middle;fontSize=12;fontColor=#717182;fontFamily=Helvetica;" vertex="1" parent="1"><mxGeometry x="0" y="-34" width="1200" height="24" as="geometry"/></mxCell>')
    for i, l in enumerate(d.lanes):
        o.append(f'        <mxCell id="lane{i}" value="{html.escape(l["label"].upper())}" style="rounded=1;whiteSpace=wrap;html=1;fillColor={l["fill"]};strokeColor=#D8D8DE;dashed=1;verticalAlign=top;align=left;spacingLeft=10;spacingTop=2;fontSize=11;fontStyle=1;fontColor=#717182;fontFamily=Helvetica;" vertex="1" parent="1"><mxGeometry x="{l["x"]}" y="{l["y"]}" width="{l["w"]}" height="{l["h"]}" as="geometry"/></mxCell>')
    for n in d.nodes:
        k = KINDS[n["kind"]]
        if k.get("shape") == "entity":
            o.append(f'        <mxCell id="{n["id"]}" value="{html.escape(n["label"])}" style="{drawio_style(n)}" vertex="1" parent="1"><mxGeometry x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" as="geometry"/></mxCell>')
            for j, line in enumerate(n["sub"].split("\n")):
                o.append(f'        <mxCell id="{n["id"]}_f{j}" value="{html.escape(line)}" style="text;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;spacingLeft=6;fontFamily=Courier New;fontSize=11;whiteSpace=wrap;html=1;" vertex="1" parent="{n["id"]}"><mxGeometry y="{28 + j * 15}" width="{n["w"]}" height="15" as="geometry"/></mxCell>')
            continue
        value = html.escape(n["label"])
        if n["sub"]:
            value += f'<br><span style="font-size:11px;color:{"#717182" if n["kind"] not in ("start", "end") else "#FFFFFF"}">{html.escape(n["sub"])}</span>'
        if n["tech"]:
            value += f'<br><span style="font-size:10px;color:#717182;font-family:Courier New">{html.escape(n["tech"])}</span>'
        o.append(f'        <mxCell id="{n["id"]}" value="{value}" style="{drawio_style(n)}" vertex="1" parent="1"><mxGeometry x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" as="geometry"/></mxCell>')
    for i, e in enumerate(d.edges):
        style = f'edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;strokeColor={e["color"]};strokeWidth=1.5;fontSize=11;fontColor=#4B4B57;fontFamily=Helvetica;endArrow=block;endFill=1;'
        if e["dashed"]:
            style += "dashed=1;"
        if e["both"]:
            style += "startArrow=block;startFill=1;"
        if not e.get("arrow", True):
            style = style.replace("endArrow=block;endFill=1;", "endArrow=none;")
        if e.get("raw"):
            style = style.replace("edgeStyle=orthogonalEdgeStyle;", "edgeStyle=none;") + ("verticalAlign=bottom;" if e.get("above") else "")
            (sx, sy), (tx, ty) = e["points"][0], e["points"][-1]
            o.append(f'        <mxCell id="e{i}" value="{html.escape(e["label"])}" style="{style}" edge="1" parent="1"><mxGeometry relative="1" as="geometry"><mxPoint x="{sx}" y="{sy}" as="sourcePoint"/><mxPoint x="{tx}" y="{ty}" as="targetPoint"/>')
            if len(e["points"]) > 2:
                o.append('          <Array as="points">' + "".join(f'<mxPoint x="{px}" y="{py}"/>' for px, py in e["points"][1:-1]) + "</Array>")
            o.append("        </mxGeometry></mxCell>")
            continue
        o.append(f'        <mxCell id="e{i}" value="{html.escape(e["label"])}" style="{style}" edge="1" parent="1" source="{e["a"]}" target="{e["b"]}"><mxGeometry relative="1" as="geometry">')
        if e["points"]:
            o.append('          <Array as="points">' + "".join(f'<mxPoint x="{px}" y="{py}"/>' for px, py in e["points"]) + "</Array>")
        o.append("        </mxGeometry></mxCell>")
    o += ["      </root>", "    </mxGraphModel>", "  </diagram>", "</mxfile>"]
    return "\n".join(o)


def emit(d):
    with open(os.path.join(OUT, d.name + ".svg"), "w") as f:
        f.write(to_svg(d))
    with open(os.path.join(OUT, d.name + ".drawio"), "w") as f:
        f.write(to_drawio(d))
    print("built", d.name)


# ======================================================================
# Diagram definitions
# ======================================================================
LEGEND_ARCH = [("app", "Client app"), ("service", "Service (own deployable, own database)"), ("odoo", "Odoo: system of record"),
               ("infra", "Shared platform"), ("external", "External provider"), ("later", "Stage 2 or 3")]


def d01_context():
    d = D("01-context", "System context: who uses Yantra and what it talks to",
          "Level 1. People on the left, Yantra in the middle, external systems on the right.", LEGEND_ARCH)
    d.n("worker", 0, 60, 170, 70, "Candidate / Worker", "applies, certifies, claims tasks, gets paid", "actor")
    d.n("reviewer", 0, 170, 170, 70, "Reviewer / Auditor", "judges submissions, flags unclear rubrics", "actor")
    d.n("ops", 0, 280, 170, 70, "Ops / TPM / Finance", "runs projects, pay windows, delivery", "actor")
    d.n("client", 0, 390, 170, 70, "Client / Buyer", "labs and environment vendors", "actor")
    d.n("lead", 0, 500, 170, 70, "Leadership", "the four numbers, kill tests", "actor")
    d.n("yantra", 300, 150, 340, 300, "Yantra", "trusted supply and verified production of AI training work: vet, bench, claim, review, pay, deliver, catalogue", "service", "one repository, services around Odoo 19 CE")
    d.n("kc", 760, 40, 190, 60, "Keycloak", "identity: OIDC for staff, JWT for workers", "infra")
    d.n("rzp", 760, 130, 190, 60, "RazorpayX", "weekly payouts, penny drop", "external")
    d.n("gst", 760, 220, 190, 60, "NIC e-invoice (GSTN)", "client invoices", "external")
    d.n("ai", 760, 310, 190, 60, "Vertex Gemini", "advisory pre-review, grading", "external")
    d.n("msg", 760, 400, 190, 60, "Email, FCM, WhatsApp", "notifications", "external")
    d.n("hubs", 760, 490, 190, 60, "Hugging Face, DataVendor, Harbor", "Stage 3 channels and artifact registry", "later")
    for a in ("worker", "reviewer", "ops", "client", "lead"):
        na = d.node(a); cy = na["y"] + na["h"] / 2
        d.e(a, "yantra", "", [(240, cy), (240, min(max(cy, 170), 430))])
    for b, lbl in (("kc", "login"), ("rzp", "payout files, webhooks"), ("gst", "e-invoice IRN"), ("ai", "prompts, verdicts"), ("msg", "messages"), ("hubs", "signed artifacts")):
        nb = d.node(b); cy = nb["y"] + nb["h"] / 2
        d.e("yantra", b, lbl, [(660, min(max(cy, 170), 430)), (660, cy)], seg=2, above=True)
    return d


def d02_containers():
    d = D("02-containers", "Containers: one repository, a ring of services around Odoo",
          "Level 2. Every service is its own deployable with its own database. The app reaches services only through the gateway.", LEGEND_ARCH)
    d.lane(0, 0, 1180, 120, "Clients")
    d.n("app", 20, 35, 300, 65, "Flutter app", "workers, reviewers, candidates, ops on mobile", "app", "app/")
    d.n("bo", 860, 35, 300, 65, "Odoo backend UI", "ops, finance, HR", "odoo")
    d.n("gw", 20, 170, 300, 70, "gateway", "Keycloak JWT, rate limits, idempotency keys, public OpenAPI", "service", "services/gateway")
    d.lane(0, 280, 1180, 230, "Service ring: one deployable and one PostgreSQL database each")
    d.n("assess", 20, 320, 180, 80, "assess", "papers, certification, skills write-back", "service", "in the Odoo image (Stage 1)")
    d.n("market", 220, 320, 180, 80, "market", "projects, batches, units, claims, price cards, delivery gate", "service")
    d.n("quality", 420, 320, 180, 80, "quality", "review claims, verdicts, audit, reason codes", "service")
    d.n("payout", 620, 320, 180, 80, "payout", "earnings, pay windows, cost ledger, rails", "service")
    d.n("notify", 820, 320, 160, 80, "notify", "email, push, WhatsApp", "service")
    d.n("hub", 20, 420, 180, 70, "hub", "artifacts, lineage, rights, entitlements", "later", "Stage 2")
    d.n("runner", 220, 420, 180, 70, "runner", "environment quality gate", "later", "Stage 2 prototype")
    d.n("tracker", 420, 420, 180, 70, "tracker", "hourly evidence", "later", "scaffold")
    d.n("analytics", 620, 420, 180, 70, "analytics", "CDC read models", "later", "scaffold")
    d.n("bus", 1000, 320, 160, 170, "NATS JetStream", "every service publishes from its outbox and subscribes; CloudEvents", "infra")
    d.n("odoo", 420, 560, 380, 80, "odoo: system of record", "worker record, bench, skills, accounting, vendor bills with TDS, client invoices", "odoo", "services/odoo, ethara_* addons")
    d.lane(0, 680, 1180, 110, "Shared platform")
    d.n("kc", 20, 710, 200, 60, "Keycloak", "OIDC staff, JWT workers and services", "infra")
    d.n("pg", 250, 710, 260, 60, "PostgreSQL", "one database per service, PgBouncer, PITR", "infra")
    d.n("redis", 540, 710, 180, 60, "Redis", "idempotency, sessions, cache", "infra")
    d.n("s3", 750, 710, 180, 60, "S3", "payloads, documents, deliveries", "infra")
    d.n("ext", 960, 710, 200, 60, "RazorpayX, Gemini, SMTP, FCM", "external providers", "external")
    d.e("app", "gw", "HTTPS, JWT")
    d.e("bo", "odoo", "", [(1010, 110), (1010, 540), (700, 540)])
    for s in ("assess", "market", "quality", "payout", "notify"):
        d.e("gw", s, "", [(170, 260), (d.node(s)["x"] + d.node(s)["w"] / 2, 260)])
    d.e("gw", "odoo", "ethara_api controllers", [(-30, 205), (-30, 600)], seg=2)
    d.e("notify", "bus", "", both=True)
    d.e("bus", "odoo", "outbox bridge", [(1080, 620)], seg=1)
    d.e("payout", "ext", "payouts", [(710, 660), (1060, 660)], dashed=True)
    return d


def d03_pipeline():
    d = D("03-build-and-release", "Build and release: one repository, affected-only CI, one release train",
          "A pull request that changes a contract must also change its consumers; a service without a runbook does not deploy.")
    d.n("pr", 0, 60, 150, 70, "Pull request", "trunk-based, short branch", "step")
    d.n("ci", 200, 60, 190, 70, "CI: path filters", "tests only for what changed", "step", "GitHub Actions")
    d.n("ct", 440, 60, 190, 70, "Contract tests", "OpenAPI and event schemas; generated clients rebuilt", "step")
    d.n("img", 680, 60, 190, 70, "Image build", "signed, SBOM, scanned, tagged per service", "step", "cosign, Harbor")
    d.n("argo", 920, 60, 170, 70, "Argo CD", "app per service, app-of-apps per environment", "infra")
    d.n("stg", 920, 190, 170, 70, "Staging", "smoke, claim-storm harness", "gate")
    d.n("prod", 920, 320, 170, 70, "Production", "canary, runbook on file", "end")
    d.n("db", 440, 190, 190, 70, "Fresh-database tests", "migrations per service from zero", "step")
    d.n("harness", 680, 190, 190, 70, "Claim-storm harness", "1.5x the largest cohort, zero errors", "gate")
    d.e("pr", "ci"); d.e("ci", "ct"); d.e("ct", "img"); d.e("img", "argo"); d.e("argo", "stg"); d.e("stg", "prod", "gate passed")
    d.e("ci", "db", "", [(295, 225)]); d.e("db", "harness"); d.e("harness", "stg")
    return d


def d04_deployment():
    d = D("04-deployment", "Deployment: Kubernetes topology for one environment",
          "Istio ingress, a Deployment per service, Odoo in four roles, shared platform services. Sized for year one; extraction triggers in the plan.", LEGEND_ARCH)
    d.n("edge", 0, 60, 1100, 60, "Istio ingress (Envoy): TLS, routes, rate limit policies, presigned URLs masked in logs", "", "infra")
    d.lane(0, 150, 1100, 200, "namespace yantra: services (Deployment + HPA + chart each)")
    xs = 20
    for name, sub in (("gateway", "2-4 pods"), ("market", "2-4 pods"), ("quality", "2 pods"), ("payout", "2 pods + cron job"), ("notify", "1-2 pods"), ("assess", "in the Odoo image")):
        d.n("svc_" + name, xs, 190, 165, 60, name, sub, "service")
        xs += 180
    d.n("odoo_http", 20, 270, 250, 60, "odoo-web", "prefork workers, HPA", "odoo")
    d.n("odoo_ws", 290, 270, 250, 60, "odoo-gevent", "websocket, no CPU HPA", "odoo")
    d.n("odoo_cron", 560, 270, 250, 60, "odoo-cron", "lease-locked jobs, outbox drain", "odoo")
    d.n("odoo_up", 830, 270, 250, 60, "odoo-upgrade", "one-shot migration job", "odoo")
    d.lane(0, 380, 1100, 120, "namespace yantra-platform")
    d.n("nats", 20, 410, 200, 60, "NATS JetStream", "3 nodes, file store", "infra")
    d.n("kc", 240, 410, 200, 60, "Keycloak", "one realm", "infra")
    d.n("redis", 460, 410, 200, 60, "Redis", "idempotency, sessions", "infra")
    d.n("obs", 680, 410, 400, 60, "Prometheus, Grafana, Loki, OpenTelemetry, Sentry", "a trace from app to ledger", "infra")
    d.lane(0, 530, 1100, 120, "managed outside the cluster")
    d.n("pg", 20, 560, 420, 60, "PostgreSQL server", "one database per service, PgBouncer transaction mode, PITR; operator in Stage 3", "infra")
    d.n("s3", 460, 560, 300, 60, "S3", "per-project prefixes, IAM roles, SSE-KMS", "infra")
    d.n("harbor", 780, 560, 300, 60, "Harbor", "signed images, SBOM; Stage 3 artifacts", "infra")
    d.e("edge", "svc_gateway", "", [(102, 140)])
    d.e("edge", "odoo_http", "", [(-20, 90), (-20, 300)])
    return d


def d05_loop():
    d = D("05-closed-loop", "The business in one loop",
          "Every arrow is an event; the accept verdict is the only money event. The stage under each box says when it exists.")
    steps = [("find", "Find", "channels measured per verified person", "later", "talent, Stage 2"),
             ("vet", "Vet", "paper from the project SOP certifies a skill", "service", "assess, Stage 1"),
             ("bench", "Bench", "verified people, evidence levels, availability", "odoo", "odoo, Stage 1"),
             ("quote", "Quote", "price card, cost per unit, margin floor", "service", "market + payout, Stage 1"),
             ("work", "Work", "assigned or open claim, rubric version on every unit", "service", "market, Stage 1"),
             ("review", "Review", "reason code, rubric-unclear flag; accept = money", "money", "quality, Stage 1"),
             ("pay", "Pay", "weekly, TDS, identity bound to the account", "service", "payout + odoo, Stage 1"),
             ("measure", "Measure", "standard signals from events", "later", "performance, Stage 2"),
             ("catalogue", "Catalogue", "artifacts with lineage, rights, quality gate", "later", "hub, Stage 2-3")]
    pos = [(0, 0), (240, 0), (480, 0), (720, 0), (960, 0), (960, 180), (720, 180), (480, 180), (240, 180)]
    for (id, lbl, sub, kind, tech), (x, y) in zip(steps, pos):
        d.n(id, x, y, 200, 110, lbl, sub, kind, tech)
    order = [s[0] for s in steps]
    for a, b in zip(order, order[1:]):
        d.e(a, b)
    d.e("catalogue", "find", "licensed artifacts fund the next bench", [(300, 345), (100, 345), (100, 150)], dashed=True, seg=2)
    return d


def flow(name, title, subtitle, steps, w=190, h=76, gap=50, per_row=5, row_gap=70, extra_edges=()):
    """Snake layout for a user flow: steps = list of (id, label, sub, kind)."""
    d = D(name, title, subtitle)
    for i, (id, lbl, sub, kind) in enumerate(steps):
        r, c = divmod(i, per_row)
        if r % 2 == 1:
            c = per_row - 1 - c
        d.n(id, c * (w + gap), r * (h + row_gap), w, h, lbl, sub, kind)
    ids = [s[0] for s in steps]
    for i, (a, b) in enumerate(zip(ids, ids[1:])):
        ra, rb = divmod(i, per_row)[0], divmod(i + 1, per_row)[0]
        if ra == rb:
            d.e(a, b)
        else:
            na = d.node(a)
            d.e(a, b, "", [(na["x"] + na["w"] / 2, na["y"] + h + row_gap / 2), (d.node(b)["x"] + w / 2, na["y"] + h + row_gap / 2)])
    for a, b, lbl, pts, dashed in extra_edges:
        d.e(a, b, lbl, pts, dashed)
    return d


def d06_flow_worker():
    steps = [("s", "Hears about Yantra", "a measured channel, never a DM", "start"),
             ("apply", "Applies", "60-second form with hard questions", "step"),
             ("paper", "Takes the paper", "generated from the project SOP, proctored", "step"),
             ("cert", "Certified", "skill verified; retake policy applies", "gate"),
             ("onboard", "Onboarding checklist", "agreements, DPDP consent, documents, PAN and bank, payout setup in the app", "step"),
             ("eligible", "ELIGIBLE", "computed, never set by hand; identity bound to the payout account", "gate"),
             ("bench", "On the bench", "skills with evidence level, availability", "step"),
             ("claim", "Claims a task", "pay shown first; one live claim; TTL", "step"),
             ("work", "Works it", "schema-rendered form; rubric version visible; can flag rubric unclear", "step"),
             ("submit", "Submits", "idempotent; a retry never duplicates", "step"),
             ("verdict", "Verdict", "accept, needs edits, reject", "decision"),
             ("earn", "Earning recorded", "on accept only", "money"),
             ("window", "Weekly window", "Saturday to Friday IST; holds; TDS", "step"),
             ("paid", "Paid Wednesday", "RazorpayX; statement in the app", "end"),
             ("back", "Back on the bench", "project ends, zero idle cost", "step")]
    d = flow("06-flow-worker", "User flow: the worker, from first contact to first payout",
             "What the person sees, in order. Red boxes are hard gates; the orange box is the only place money is created.", steps)
    d.e("verdict", "work", "needs edits", [(d.node("verdict")["x"] + 95, d.node("verdict")["y"] - 30), (d.node("work")["x"] + 95, d.node("work")["y"] + 76 + 30)], dashed=True)
    return d


def d07_flow_reviewer():
    steps = [("s", "Reviewer queue", "next submission, never own work", "start"),
             ("claim", "Claims a review", "one live review claim", "step"),
             ("judge", "Judges", "side by side with the rubric version the unit carries", "step"),
             ("reason", "Reason code", "required on needs-edits and reject; client-caused codes are billable", "step"),
             ("unclear", "Rubric unclear?", "flag goes to the TPM", "decision"),
             ("audit", "Audit sample", "10% of accepts re-judged by an auditor", "gate"),
             ("canon", "Canonical verdict", "the one money event", "money"),
             ("earn", "Review earning", "paid in the same weekly window", "step"),
             ("e", "Next submission", "", "end")]
    d = flow("07-flow-reviewer", "User flow: the reviewer", "Reason codes make quality history survive a rubric change; the audit sample keeps reviewers honest.", steps)
    return d


def d08_flow_project():
    steps = [("s", "Client brief", "task type, volume, deadline, quality bar", "start"),
             ("setup", "Project setup", "schema, rubric v1, quality policy, rate card", "step"),
             ("price", "Price card", "unit price frozen next to unit pay; margin floor checked", "step"),
             ("floor", "Below floor?", "warn, record approval", "decision"),
             ("import", "Batch import", "dry run reports every bad line", "step"),
             ("publish", "Publish", "freezes pay and price; assigned or open mode", "gate"),
             ("work", "Claims and reviews", "workers and reviewers, weeks 1-n", "step"),
             ("gate", "Delivery gate", "every line validated; one bad line holds the batch", "gate"),
             ("manifest", "Manifest", "checksums, provenance, rubric version", "step"),
             ("invoice", "Invoice", "accepted units x rate; e-invoice if Indian", "money"),
             ("margin", "Margin report", "invoice minus every cost line", "step"),
             ("bench", "People return to the bench", "the four numbers update", "end")]
    return flow("08-flow-client-project", "User flow: ops and the client, from brief to invoice",
                "One project is configuration, not a new app. The export gate and the margin report close the loop with the client.", steps)


def d09_flow_pay():
    steps = [("s", "Friday 23:59 IST", "window closes", "start"),
             ("holds", "Apply holds", "first payout 7 days; integrity holds before payout, never clawbacks", "step"),
             ("bills", "Vendor bills", "one self-billed bill per worker with TDS", "step"),
             ("approve", "Two approvals", "finance lead plus one; caps per window", "gate"),
             ("rail", "RazorpayX", "bank file as fallback", "money"),
             ("webhook", "Webhook", "signed, replay window", "step"),
             ("recon", "Reconciliation", "earnings = bills = payouts net + TDS, to the paisa; alerts, never auto-adjusts", "gate"),
             ("stmt", "Statements", "in the app; disputes answered within the next window", "end")]
    return flow("09-flow-pay-window", "User flow: finance, the weekly pay window", "Runs every week from the first dogfood batch. Zero deltas is the gate.", steps, per_row=4)


def d10_sequence():
    d = D("10-sequence-claim-to-pay", "Sequence: one task from claim to pay, system view",
          "Solid arrows are synchronous calls through the gateway; dashed arrows are events on NATS.")
    cols = [("app", "Flutter app", "app"), ("gw", "gateway", "service"), ("market", "market", "service"), ("quality", "quality", "service"),
            ("payout", "payout", "service"), ("bus", "NATS", "infra"), ("odoo", "odoo", "odoo")]
    X = {}
    for i, (id, lbl, kind) in enumerate(cols):
        x = i * 170
        X[id] = x + 70
        d.n(id, x, 0, 140, 44, lbl, "", kind)
    msgs = [("app", "gw", "POST /claims (Idempotency-Key)", 90),
            ("gw", "market", "claim: SKIP LOCKED, TTL", 125),
            ("market", "gw", "unit + presigned payload URL", 160),
            ("gw", "app", "200, one live claim", 195),
            ("app", "gw", "POST /submissions", 250),
            ("gw", "market", "store answer, close claim", 285),
            ("market", "bus", "work.unit.submitted", 320, True),
            ("bus", "quality", "review task created", 355, True),
            ("quality", "bus", "quality.verdict.accepted (canonical)", 430, True),
            ("bus", "payout", "earning recorded", 465, True),
            ("bus", "market", "unit accepted, delivery count", 500, True),
            ("payout", "bus", "payout.window.closed (weekly)", 560, True),
            ("bus", "odoo", "vendor bill with TDS; two approvals", 595, True),
            ("odoo", "bus", "payout.paid (RazorpayX webhook)", 650, True),
            ("bus", "app", "statement updated", 685, True)]
    H = 730
    for id in X:
        d.e(id, id, "", [(X[id], 44), (X[id], H)], dashed=True, color="#C9C9D2", raw=True, arrow=False)
    for m in msgs:
        a, b, lbl, y = m[:4]
        dashed = len(m) > 4
        d.e(a, b, lbl, [(X[a], y), (X[b], y)], dashed=dashed, raw=True, above=True)
    return d


def d11_data_model():
    d = D("11-data-model", "Data model: the entities that carry the loop",
          "Names follow DATAMODEL.md; rubric_version, reason_code, unit_price and the cost fields are this plan's additions. Ids cross boundaries, foreign keys never do.")
    ent = [("worker", 0, 0, "worker (odoo)", "id, partner_ref, status\nagreements, consent\nbank_account (one)\npayout_identity_bound"),
           ("skill", 0, 150, "worker_skill (odoo)", "worker_id, skill\nevidence: claimed |\n verified | proven\navailability_until"),
           ("profile", 0, 300, "worker_profile (market)", "read model from events\nodoo_partner_ref\ncert gates, tier\neligible"),
           ("project", 260, 0, "client_project (market)", "id, client_org_id\nschema, quality_policy\nrubric_version\nrate_card_id"),
           ("batch", 260, 150, "work_batch (market)", "project_id, mode\nunit_pay, unit_price (frozen)\nmargin_floor, approval\nstatus"),
           ("unit", 520, 0, "work_unit (market)", "batch_id, payload_uri\nrubric_version\nstatus, cost fields\naccepted_at"),
           ("claim", 520, 150, "claim + submission (market)", "unit_id, worker_id\nidempotency_key (unique)\nexpires_at\nsubmission version"),
           ("review", 780, 0, "review (quality)", "unit_id, reviewer_id\nverdict, reason_code\nrubric_unclear\naudit_of, canonical"),
           ("earning", 780, 150, "earning (payout)", "worker_id, unit_id\namount, kind (work|review)\nwindow_id, hold\nverdict_event_id"),
           ("window", 1040, 0, "pay_window (payout)", "sat_fri_ist, status\napprovals (2)\nrail_batch_id\nreconciled_at"),
           ("bill", 1040, 150, "vendor_bill (odoo)", "worker_id, window_id\namount, tds\nstate\npayment_ref"),
           ("delivery", 520, 300, "delivery (market)", "batch_id, manifest\nchecksums, provenance\ninvoice_id"),
           ("artifact", 780, 300, "artifact (hub, Stage 2)", "version, card, lineage\nrights, openenv_version\nentitlement, exclusivity")]
    for id, x, y, lbl, sub in ent:
        d.n(id, x, y, 220, 110, lbl, sub, "entity")
    d.e("worker", "skill"); d.e("skill", "profile", "events", dashed=True); d.e("project", "batch"); d.e("batch", "unit", "", [(480, 190), (480, 55)]); d.e("unit", "claim")
    d.e("claim", "profile", "worker_id", [(630, 355)], dashed=True)
    d.e("unit", "review"); d.e("review", "earning"); d.e("earning", "window", "", [(1000, 205), (1000, 55)]); d.e("window", "bill")
    d.e("batch", "delivery", "", [(370, 355)]); d.e("delivery", "artifact", "lineage", dashed=True)
    return d


def d12_events():
    d = D("12-events", "Events: who publishes what, who consumes it",
          "CloudEvents on NATS JetStream. Every producer writes to its own outbox in the same transaction; a relay publishes.")
    prods = [("p_odoo", "odoo", "odoo"), ("p_market", "market", "service"), ("p_quality", "quality", "service"), ("p_payout", "payout", "service"), ("p_assess", "assess", "service")]
    for i, (id, lbl, kind) in enumerate(prods):
        d.n(id, 0, i * 90, 150, 60, lbl, "", kind)
    subs = [("worker.eligible", "p_odoo"), ("worker.skill.verified", "p_assess"), ("work.unit.published", "p_market"), ("work.unit.submitted", "p_market"),
            ("quality.verdict.accepted", "p_quality"), ("quality.verdict.rejected", "p_quality"), ("payout.window.closed", "p_payout"), ("payout.paid", "p_odoo"), ("delivery.shipped", "p_market")]
    pidx = {p[0]: k for k, p in enumerate(prods)}
    for i, (s, p) in enumerate(subs):
        d.n("s_" + s, 300, i * 50, 260, 36, s, "", "subject")
        np_, cy = d.node(p), i * 50 + 18
        mx = 180 + pidx[p] * 18
        d.e(p, "s_" + s, "", [(mx, min(max(cy, np_["y"] + 14), np_["y"] + np_["h"] - 14)), (mx, cy)])
    cons = [("c_market", "market", "worker read model, unit status, delivery", "service"), ("c_quality", "quality", "review tasks", "service"), ("c_payout", "payout", "earnings, holds", "service"),
            ("c_odoo", "odoo", "bills, invoices, bench", "odoo"), ("c_notify", "notify", "messages", "service"), ("c_perf", "performance (Stage 2)", "signals", "later")]
    for i, (id, lbl, sub, kind) in enumerate(cons):
        d.n(id, 760, i * 80, 200, 60, lbl, sub, kind)
    wiring = [("worker.eligible", "c_market"), ("worker.skill.verified", "c_market"), ("work.unit.published", "c_notify"), ("work.unit.submitted", "c_quality"),
              ("quality.verdict.accepted", "c_payout"), ("quality.verdict.accepted", "c_market"), ("quality.verdict.rejected", "c_notify"), ("payout.window.closed", "c_odoo"),
              ("payout.paid", "c_notify"), ("delivery.shipped", "c_odoo"), ("quality.verdict.accepted", "c_perf")]
    cidx = {c[0]: k for k, c in enumerate(cons)}
    for s, c in wiring:
        ns, nc = d.node("s_" + s), d.node(c)
        cy = ns["y"] + 18
        mx = 600 + cidx[c] * 18
        d.e("s_" + s, c, "", [(mx, cy), (mx, min(max(cy, nc["y"] + 14), nc["y"] + nc["h"] - 14))])
    return d


def d13_timeline():
    d = D("13-stages-timeline", "The plan on a timeline: stages, steps and gates",
          "Left: the step and the number its gate must show. Right: when it runs, in weeks.")
    L, WK = 420, 36
    for w in range(0, 31, 2):
        d.n(f"w{w}", L + w * WK - 10, 0, 40, 20, f"W{w}", "", "note")
    rows = [("s0", 0, 2, "Stage 0: lock and validate", "3 bottleneck statements; baseline sheet", "step"),
            ("f", 1, 2, "Foundations", "empty service deploys signed; DB under 100 connections", "service"),
            ("i", 3, 4, "Identity, bench, onboarding", "20 synthetic applicants ELIGIBLE, no DB edits", "service"),
            ("m", 5, 7, "Market core and review", "500 workers, 2,000 units: 0 double claims, p99 < 500 ms", "service"),
            ("mo", 8, 9, "Money and margin", "earnings = bills = payouts net + TDS, to the paisa", "money"),
            ("dl", 10, 10, "Delivery and dogfood", "gate holds on one bad line; a real window paid", "service"),
            ("pp", 11, 12, "First paying pilot", "one batch invoiced; one pay cycle; zero deltas", "gate"),
            ("s2", 13, 30, "Stage 2: Talent, Performance, Hub", "3 dashboards retired; one vendor paying", "later"),
            ("s3", 30, 30, "Stage 3: environment factory (month 8 on)", "first exclusive deal as a single-member entitlement", "later")]
    for i, (id, a, b, lbl, sub, kind) in enumerate(rows):
        y = 40 + i * 58
        d.n("l" + id, 0, y, L - 30, 44, lbl + "\n" + sub, "", "note")
        if id == "s3":
            d.n(id, L, y + 4, 31 * WK, 36, "", "", kind)
        else:
            d.n(id, L + a * WK, y + 4, (b - a + 1) * WK, 36, "", "", kind)
    for w in range(0, 31, 2):
        d.e(f"w{w}", f"w{w}", "", [(L + w * WK, 24), (L + w * WK, 40 + len(rows) * 58)], raw=True, arrow=False, color="#ECECF0")
    return d


def d14_factory():
    steps = [("s", "Vertical chosen", "after two buyer conversations", "start"),
             ("author", "Authoring tasks", "agentic unit types in market", "step"),
             ("build", "Environment built", "OpenEnv-conformant, pinned version", "step"),
             ("gate", "Runner gate", "determinism replay, pass-rate band, reward-hack audit; a finding is a hard fail", "gate"),
             ("qa", "Human QA", "calibrated reviewers, seeded gold", "step"),
             ("sign", "Signed and listed", "cosign, SBOM, provenance; hub entry with lineage and rights", "step"),
             ("ent", "Entitlement", "exclusive or shared", "decision"),
             ("buyer", "Delivered to the buyer", "Harbor-scoped pull token", "money"),
             ("hubs", "Listed on hubs", "non-exclusive surplus as a channel", "end")]
    d = flow("14-environment-factory", "Stage 3: the environment factory", "The quality gate is the product. Nothing ships that the runner can hack.", steps)
    d.e("gate", "author", "fail", [(d.node("gate")["x"] + 95, -40), (d.node("author")["x"] + 95, -40)], dashed=True)
    return d


def d15_enhanced_stage1():
    d = D("15-enhanced-stage1", "Enhanced plan: four deployables in Stage 1, ten services in the code",
          "Each module keeps its own schema, contract and outbox. The deployment composes them; a split later is a chart change.", LEGEND_ARCH)
    d.lane(0, 0, 1180, 120, "Clients")
    d.n("app", 20, 35, 300, 65, "Flutter app", "workers, reviewers, candidates, ops on mobile", "app", "app/")
    d.n("bo", 860, 35, 300, 65, "Odoo backend UI", "ops, finance, HR", "odoo")
    d.n("gw", 20, 170, 300, 70, "gateway", "deployable 1: JWT, rate limits, idempotency, public OpenAPI", "service", "services/gateway")
    d.lane(0, 280, 560, 240, "Deployable 2: work (one process, three schemas)", fill="#F5F8FF")
    d.n("market", 20, 320, 160, 80, "market", "projects, batches, units, claims, price cards, delivery gate", "service", "schema market")
    d.n("quality", 200, 320, 160, 80, "quality", "review claims, verdicts, audit, reason codes", "service", "schema quality")
    d.n("notify", 380, 320, 160, 80, "notify", "email, push, WhatsApp", "service", "schema notify")
    d.n("rule", 20, 420, 520, 70, "Module rules\na module imports only packages/*; its own database role; events out through its outbox, even to a sibling; one migration job per module", "", "note")
    d.lane(580, 280, 400, 240, "Deployable 3: money", fill="#FFF9F3")
    d.n("payout", 600, 320, 360, 80, "payout", "earnings, pay windows, holds, cost ledger, rail adapters; its own release train and deploy freeze", "money", "schema payout")
    d.n("later", 600, 420, 360, 70, "hub, runner, tracker, analytics", "directories with a contract and a health endpoint; not deployed in Stage 1", "later")
    d.n("bus", 1000, 320, 160, 170, "NATS JetStream", "every module publishes from its outbox; CloudEvents; replay", "infra")
    d.n("odoo", 300, 560, 580, 80, "odoo: deployable 4, the system of record", "worker record, bench, accounting, vendor bills with TDS, client invoices; the Assessment v2 engine behind the assess contract", "odoo", "services/odoo, ethara_* addons")
    d.lane(0, 680, 1180, 110, "Shared platform, one region in India")
    d.n("kc", 20, 710, 200, 60, "Keycloak", "OIDC staff, JWT workers and services", "infra")
    d.n("pg", 250, 710, 260, 60, "PostgreSQL", "one schema and one role per module, PgBouncer, PITR", "infra")
    d.n("redis", 540, 710, 180, 60, "Redis", "idempotency, sessions, cache", "infra")
    d.n("s3", 750, 710, 180, 60, "S3", "payloads, documents, deliveries, backups in country", "infra")
    d.n("ext", 960, 710, 200, 60, "RazorpayX, Gemini, SMTP, FCM", "external providers", "external")
    d.e("app", "gw", "HTTPS, JWT")
    d.e("bo", "odoo", "", [(1010, 110), (1010, 540), (700, 540)])
    for s in ("market", "quality", "notify"):
        d.e("gw", s, "", [(170, 260), (d.node(s)["x"] + d.node(s)["w"] / 2, 260)])
    d.e("gw", "payout", "", [(170, 260), (780, 260)])
    d.e("gw", "odoo", "ethara_api controllers", [(-30, 205), (-30, 600)], seg=2)
    d.e("payout", "bus", "", both=True)
    d.e("bus", "odoo", "outbox bridge", [(1080, 620)], seg=0)
    d.e("payout", "ext", "payouts", [(990, 386), (990, 660), (1060, 660)], dashed=True, seg=2)
    return d


def d16_migration():
    steps = [("s", "Today", "113 addons, about 25 task apps, 29 dashboards on the current platform", "start"),
             ("c", "1. Connect", "Keycloak in front of both; one person id; an outbox addon emits events from existing projects", "step"),
             ("g1", "Gate", "a current project's accept events on the bus within a minute; no screen changed", "gate"),
             ("r", "2. Read models first", "Performance views and the margin report built on events; old projects untouched", "step"),
             ("g2", "Gate", "three per-project dashboards retired; same numbers on the same weeks", "gate"),
             ("n", "3. New projects on the engine", "every project after the pilot is a schema and a rubric in market, not an addon", "step"),
             ("g3", "Gate", "a new project type stands up in under a week with no new addon", "gate"),
             ("p", "4. Port at renewal", "units imported with a dry run; reviewers on the bench; the addon retired; an ending project is archived, not ported", "step"),
             ("g4", "Gate", "a full pay window on Yantra with zero delta; the old addon removed from the image", "gate"),
             ("e", "Half of all units on market", "within six months of the pilot (assumption)", "end")]
    return flow("16-migration-path", "Moving the current platform over: the strangler path",
                "Nothing live is rewritten. A project moves at its own renewal; a project that is ending never moves.", steps, w=200, h=96, gap=40, per_row=5)


def d17_enhanced_timeline():
    d = D("17-enhanced-timeline", "The enhanced plan on a timeline: sixteen weeks and a hardening week",
          "Left: the step and the number its gate must show. Right: when it runs, in weeks.")
    L, WK = 420, 34
    for w in range(0, 33, 2):
        d.n(f"w{w}", L + w * WK - 10, 0, 40, 20, f"W{w}", "", "note")
    rows = [("s0", 0, 2, "Stage 0: lock and validate", "3 bottleneck statements; baseline sheet", "step"),
            ("f", 1, 2, "Foundations + strangler move 1", "empty work deployable ships signed; events on the bus", "service"),
            ("i", 3, 5, "Identity, bench, onboarding", "20 synthetic applicants ELIGIBLE, no DB edits", "service"),
            ("m", 6, 9, "Market core and review", "500 workers, 2,000 units: 0 double claims, p99 < 500 ms", "service"),
            ("mo", 10, 11, "Money and margin", "earnings = bills = payouts net + TDS, to the paisa", "money"),
            ("dl", 12, 13, "Delivery and dogfood", "gate holds on one bad line; a real window paid", "service"),
            ("h", 14, 14, "Hardening", "pen test fixed; restore within targets; split rehearsed", "gate"),
            ("pp", 15, 16, "First paying pilot", "one batch invoiced; one pay cycle; zero deltas", "gate"),
            ("s2", 17, 32, "Stage 2: Talent, Performance, Hub", "3 dashboards retired; one vendor paying", "later")]
    for i, (id, a, b, lbl, sub, kind) in enumerate(rows):
        y = 40 + i * 58
        d.n("l" + id, 0, y, L - 30, 44, lbl + "\n" + sub, "", "note")
        d.n(id, L + a * WK, y + 4, (b - a + 1) * WK, 36, "", "", kind)
    for w in range(0, 33, 2):
        d.e(f"w{w}", f"w{w}", "", [(L + w * WK, 24), (L + w * WK, 40 + len(rows) * 58)], raw=True, arrow=False, color="#ECECF0")
    return d


if __name__ == "__main__":
    for build in (d01_context, d02_containers, d03_pipeline, d04_deployment, d05_loop, d06_flow_worker, d07_flow_reviewer,
                  d08_flow_project, d09_flow_pay, d10_sequence, d11_data_model, d12_events, d13_timeline, d14_factory,
                  d15_enhanced_stage1, d16_migration, d17_enhanced_timeline):
        emit(build())
