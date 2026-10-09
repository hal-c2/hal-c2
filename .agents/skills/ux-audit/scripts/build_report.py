#!/usr/bin/env python3
"""Build the HTML audit report from an audit dir's findings.jsonl and coverage.jsonl.

Usage:
  build_report.py --dir AUDIT_DIR [--title "..."] [--env "..."]
Writes AUDIT_DIR/report/index.html and copies the referenced screenshots into
AUDIT_DIR/report/shots. Prints every screenshot it could not find.
"""

from __future__ import annotations

import argparse
import html
import json
import shutil
from collections import Counter, defaultdict
from pathlib import Path

SEV_ORDER = ["high", "medium", "low", "info", "ok"]
SEV_LABEL = {"high": "High", "medium": "Medium", "low": "Low", "info": "Info", "ok": "OK as-is"}
# Inline, so the report runs no script: it holds real conversation text and opens from disk.
STYLE = """
* { box-sizing: border-box }
body { margin: 0; font: 14px/1.5 system-ui, sans-serif; background: #f8fafc; color: #1e293b }
a { color: #4338ca; text-decoration: none } a:hover { text-decoration: underline }
code, .id { font-family: ui-monospace, monospace }
code { background: #f1f5f9; border-radius: 4px; padding: 1px 4px }
header { position: sticky; top: 0; z-index: 1; background: #fff; border-bottom: 1px solid #e2e8f0 }
header > div, main { max-width: 80rem; margin: 0 auto; padding: 12px 24px }
header > div { display: flex; justify-content: space-between; align-items: center }
header h1 { margin: 0; font-size: 18px }
nav { display: flex; gap: 16px } nav a { color: #475569 }
@media (max-width: 768px) { nav { display: none } }
.kicker { font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: .05em; color: #4f46e5 }
section { margin-top: 48px; scroll-margin-top: 80px }
h2 { margin: 0; font-size: 24px; color: #0f172a }
h3 { margin: 32px 0 8px; font-size: 18px }
h3.area { border-bottom: 1px solid #cbd5e1; padding-bottom: 4px; font-size: 20px }
h3.gap { color: #b91c1c }
h4 { margin: 8px 0 0; font-size: 18px; color: #0f172a }
.muted { font-size: 12px; font-weight: normal; color: #64748b }
.prose { max-width: 48rem; color: #334155 }
.badge { display: inline-flex; border: 1px solid; border-radius: 999px; padding: 1px 10px; font-size: 12px; font-weight: 600 }
.high { background: #fee2e2; color: #991b1b; border-color: #fecaca }
.medium { background: #fef3c7; color: #92400e; border-color: #fde68a }
.low { background: #e0f2fe; color: #075985; border-color: #bae6fd }
.info { background: #f1f5f9; color: #334155; border-color: #e2e8f0 }
.ok { background: #ecfdf5; color: #065f46; border-color: #a7f3d0 }
.fixed { background: #f5f3ff; color: #5b21b6; border-color: #ddd6fe }
.box { background: #fff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 20px }
.stats { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); margin-top: 24px }
.stat { font-size: 30px; font-weight: 700 }
.cards > * + * { margin-top: 20px }
article { scroll-margin-top: 96px; box-shadow: 0 1px 2px #0000000d }
.head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px }
.head .id { color: #94a3b8 }
.desc { margin: 8px 0 0; white-space: pre-line; color: #334155 }
summary { cursor: pointer; font-size: 12px; color: #64748b }
pre { overflow-x: auto; border-radius: 4px; background: #0f172a; color: #f1f5f9; padding: 12px; font-size: 12px }
.shots { display: grid; gap: 12px; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); margin-top: 12px }
figure { margin: 0; min-width: 0 }
figure img { display: block; width: 100%; height: 224px; object-fit: contain; object-position: top; border: 1px solid #e2e8f0; border-radius: 8px; background: #f8fafc }
figcaption { margin-top: 4px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: 11px ui-monospace, monospace; color: #64748b }
.chips { margin-top: 8px; font-size: 12px; color: #475569 }
.note { margin-top: 12px; border: 1px solid; border-radius: 8px; padding: 12px }
.table { overflow-x: auto; margin-top: 12px; background: #fff; border: 1px solid #e2e8f0; border-radius: 12px }
table { min-width: 100%; border-collapse: collapse }
th { background: #f8fafc; text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: .05em; color: #64748b }
th, td { padding: 8px 12px; vertical-align: top }
tbody tr { border-top: 1px solid #f1f5f9 }
.none { color: #94a3b8 }
"""
LEGEND = (
    "<b>High</b> = blocks or misleads a task, shows the user internals they cannot act on, or loses work; "
    "<b>Medium</b> = clear usability cost, workaround exists; <b>Low</b> = polish / consistency; "
    "<b>Info</b> = observation; <b>OK as-is</b> = reviewed and justified."
)
# The checklist's areas. A coverage row counts for the area its "area" starts with, so an
# area nobody opened shows up as a gap instead of passing silently.
REQUIRED_AREAS = [
    "Shell and header",
    "Sidebar",
    "Home and centre",
    "Timeline",
    "Live turn",
    "Composer",
    "Right panel › Diff",
    "Right panel › Files",
    "Right panel › Agents",
    "Right panel › Previews",
    "Right panel › Device",
    "Right panel › Pull requests",
    "Terminal",
    "Command palette",
    "Settings",
    "Dialogs and toasts",
    "Connection and errors",
    "Keyboard",
]
E = html.escape


def _list(v) -> list:
    if v is None or v == "":
        return []
    return v if isinstance(v, list) else [v]


def _jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with path.open(encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def shot_name(s) -> str:
    """A shot as its file name in shots/; a bare name gets the .png that ux shot writes."""
    name = Path(str(s)).name
    return name if Path(name).suffix else f"{name}.png"


def load_findings(path: Path) -> list[dict]:
    rows, seen = [], set()
    for r in _jsonl(path):
        # A resumed audit appends to the log; a repeated id would collapse two
        # findings onto one card here and one sub-issue in github_issues.py.
        if r["id"] in seen:
            raise ValueError(f"finding {r['id']!r} appears more than once in {path}")
        seen.add(r["id"])
        sev = str(r.get("sev", "info")).lower()
        # A typo such as "hihg" must not silently downgrade a finding.
        if sev not in SEV_ORDER:
            raise ValueError(f"finding {r['id']!r}: sev {sev!r} is not one of {'|'.join(SEV_ORDER)}")
        why_ok = r.get("why_ok") or ""
        # Every item judged fine says why; a bare "ok" publishes an unexplained pass.
        if sev == "ok" and not str(why_ok).strip():
            raise ValueError(f"finding {r['id']!r}: sev 'ok' needs a why_ok")
        rows.append(
            {
                "id": r["id"],
                "sev": sev,
                "area": r.get("area") or "General",
                "title": r.get("title", r["id"]),
                "desc": r.get("desc") or "",
                "evidence": r.get("evidence"),
                "shots": [shot_name(s) for s in _list(r.get("shots"))],
                "where": _list(r.get("where")),
                "ledger": _list(r.get("ledger")),
                "solutions": _list(r.get("solutions")),
                "why_ok": why_ok,
                "fixed": r.get("fixed") or "",
                "related": _list(r.get("related")),
            }
        )
    return rows


def badge(sev: str) -> str:
    return f'<span class="badge {sev}">{SEV_LABEL[sev]}</span>'


def figure(shot: str) -> str:
    return (
        f'<figure><a href="shots/{E(shot)}" target="_blank" rel="noopener">'
        f'<img src="shots/{E(shot)}" loading="lazy" alt="{E(shot)}"></a>'
        f'<figcaption title="{E(shot)}">{E(shot)}</figcaption></figure>'
    )


def chips(label: str, items: list, link: bool = False) -> str:
    if not items:
        return ""
    if link:
        body = ", ".join(f'<a href="#{E(i)}">{E(i)}</a>' for i in items)
    else:
        body = " · ".join(f"<code>{E(str(i))}</code>" for i in items)
    return f'<div class="chips"><b>{label}:</b> {body}</div>'


def card(f: dict) -> str:
    head = f'<a href="#{f["id"]}" class="id">{f["id"]}</a>{badge(f["sev"])}'
    if f["fixed"]:
        head += '<span class="badge fixed">Fixed</span>'
    head += f'<span class="muted">{E(f["area"])}</span>'
    parts = [
        f'<article id="{f["id"]}" class="box">',
        f'<div class="head">{head}</div>',
        f'<h4>{E(f["title"])}</h4>',
    ]
    if f["desc"]:
        parts.append(f'<p class="desc">{E(f["desc"])}</p>')
    if f["evidence"]:
        ev = f["evidence"] if isinstance(f["evidence"], str) else json.dumps(f["evidence"], indent=1, ensure_ascii=False)
        parts.append(f"<details><summary>Evidence</summary><pre>{E(ev)}</pre></details>")
    if f["shots"]:
        parts.append('<div class="shots">' + "".join(figure(s) for s in f["shots"]) + "</div>")
    parts += [chips("Where", f["where"]), chips("Ledger", f["ledger"]), chips("Related", f["related"], link=True)]
    if f["fixed"]:
        parts.append(f'<div class="note fixed"><b>Fixed:</b> {E(str(f["fixed"]))}</div>')
    if f["why_ok"]:
        parts.append(f'<div class="note ok"><b>Why it is fine as it is:</b> {E(f["why_ok"])}</div>')
    if f["solutions"]:
        parts.append(
            '<div class="prose"><b>Possible solutions</b><ol>'
            + "".join(f"<li>{E(str(s))}</li>" for s in f["solutions"])
            + "</ol></div>"
        )
    parts.append("</article>")
    return "\n".join(p for p in parts if p)


def table(headers: list[str], rows: list[list[str]]) -> str:
    th = "".join(f"<th>{h}</th>" for h in headers)
    trs = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f'<div class="table"><table><thead><tr>{th}</tr></thead><tbody>{trs}</tbody></table></div>'


def _size_key(size: str) -> tuple:
    try:
        w, h = size.split("x")
        return (-int(w), -int(h))
    except ValueError:
        return (0, 0)


def unvisited(coverage: list[dict]) -> list[str]:
    # A skipped row is a reported gap with a reason; it is listed under "Not covered".
    seen = [r["area"].lower() for r in coverage]
    return [a for a in REQUIRED_AREAS if not any(s.startswith(a.lower()) for s in seen)]


def coverage_section(coverage: list[dict]) -> str:
    if not coverage:
        return '<p class="prose">No coverage recorded.</p>'
    seen = [r for r in coverage if not r.get("skipped")]
    skipped = [r for r in coverage if r.get("skipped")]
    areas = list(dict.fromkeys(r["area"] for r in coverage))
    sizes = sorted({r.get("size", "?") for r in seen}, key=_size_key)
    cells: dict[tuple, list] = defaultdict(list)
    for r in seen:
        cells[(r["area"], r.get("size", "?"))].append(r)
    rows = []
    for area in areas:
        row = [E(area)]
        for size in sizes:
            links = [
                f'<a href="shots/{E(shot_name(r["shot"]))}" target="_blank">{E(r.get("appearance", "?"))}</a>'
                if r.get("shot")
                else E(r.get("appearance", "?"))
                for r in cells[(area, size)]
            ]
            row.append(" ".join(links) or '<span class="none">–</span>')
        rows.append(row)
    out = table(["Area"] + [E(s) for s in sizes], rows)
    gaps = unvisited(coverage)
    if gaps:
        out += '<h3 class="gap">Checklist areas never visited</h3><ul>' + "".join(
            f"<li>{E(a)}</li>" for a in gaps
        ) + "</ul>"
    if skipped:
        out += '<h3>Not covered</h3>' + table(
            ["Area", "Reason"], [[E(r["area"]), E(r["skipped"])] for r in skipped]
        )
    return out


def build(args) -> None:
    root = Path(args.dir)
    findings = load_findings(root / "findings.jsonl")
    coverage = _jsonl(root / "coverage.jsonl")
    out = root / "report"
    shots_out = out / "shots"
    # Only evidence the current logs reference: a stale copy from an earlier build must not hide a missing shot.
    shutil.rmtree(shots_out, ignore_errors=True)
    shots_out.mkdir(parents=True)
    wanted = {s for f in findings for s in f["shots"]} | {shot_name(r["shot"]) for r in coverage if r.get("shot")}
    missing = []
    for s in sorted(wanted):
        src = root / "shots" / s
        if src.exists():
            shutil.copy2(src, shots_out / s)
        else:
            missing.append(s)

    counts = Counter(f["sev"] for f in findings)
    issues = sorted((f for f in findings if f["sev"] != "ok"), key=lambda f: (SEV_ORDER.index(f["sev"]), f["id"]))
    oks = [f for f in findings if f["sev"] == "ok"]
    by_area: dict[str, list] = defaultdict(list)
    for f in issues:
        by_area[f["area"].split(" › ")[0]].append(f)

    def sec(id_, title, body):
        return f'<section id="{id_}"><h2>{title}</h2>{body}</section>'

    stat_cards = "".join(
        f'<div class="box"><div class="stat">{counts.get(s, 0)}</div>{badge(s)}</div>'
        for s in SEV_ORDER
    )
    top = "".join(
        f'<li><a class="id" href="#{f["id"]}">{f["id"]}</a> {E(f["title"])}</li>'
        for f in issues
        if f["sev"] == "high"
    )
    index_rows = [
        [f'<a class="id" href="#{f["id"]}">{f["id"]}</a>', badge(f["sev"]), E(f["area"]), E(f["title"])]
        for f in sorted(findings, key=lambda f: (SEV_ORDER.index(f["sev"]), f["id"]))
    ]
    summary = (
        f'<div class="stats">{stat_cards}</div>'
        f'<p class="prose">{len(findings)} entries. {LEGEND}</p>'
        f'<h3>Highest-impact items</h3><ol>{top or "<li>none</li>"}</ol>'
        f'<h3>Index</h3>{table(["Id", "Severity", "Area", "Title"], index_rows)}'
    )
    method = """<ol class="prose">
<li>The Qt desktop (<code>hal-c2-qt</code>) in the <code>mise run desktop:cua</code> sandbox: a headless sway with its own bus and AT-SPI registry, driven by cua-driver, against a scratch MC seeded with a read-only snapshot of real data.</li>
<li>The checklist: every area at several window sizes, with the sidebar and right panel open and closed, in light, dark and a custom theme; every control clicked and every flow completed, mutating flows in a scratch project only; keyboard-only passes. <a href="#coverage">Coverage</a> records what this audit actually visited and what it skipped.</li>
<li>Findings checked against the code behind them, the <code>features/</code> ledger and the legacy web app; severities argued against the ui-ux-pro-max guidelines; items judged fine carry a justification.</li></ol>"""
    findings_html = "".join(
        f'<h3 class="area">{E(area)} <span class="muted">({len(fs)})</span></h3><div class="cards">'
        + "\n".join(card(f) for f in fs)
        + "</div>"
        for area, fs in by_area.items()
    )
    ok_html = '<div class="cards">' + "\n".join(card(f) for f in oks) + "</div>"
    env_html = f'<p class="prose desc">{E(args.env)}</p>'
    nav = "".join(
        f'<a href="#{i}">{t}</a>'
        for i, t in [("summary", "Summary"), ("method", "Method"), ("findings", "Findings"), ("ok", "OK as-is"), ("coverage", "Coverage"), ("environment", "Environment")]
    )
    doc = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{E(args.title)}</title><style>{STYLE}</style></head>
<body>
<header><div><div><div class="kicker">apps/desktop-qt</div><h1>{E(args.title)}</h1></div><nav>{nav}</nav></div></header>
<main>
{sec("summary", "Summary", summary)}
{sec("method", "Method", method)}
{sec("findings", f"Findings by area ({len(issues)})", findings_html)}
{sec("ok", f"Reviewed and fine as-is ({len(oks)})", ok_html)}
{sec("coverage", "Coverage", coverage_section(coverage))}
{sec("environment", "Environment", env_html)}
</main></body></html>"""
    (out / "index.html").write_text(doc, encoding="utf-8")
    print(f"findings {len(findings)}: " + ", ".join(f"{s} {counts.get(s, 0)}" for s in SEV_ORDER))
    print(f"missing shots: {missing}")
    print(f"checklist areas never visited: {unvisited(coverage)}")
    print(f"report: {out / 'index.html'}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="the audit dir bootstrap.sh made")
    ap.add_argument("--title", default="HAL-C2 desktop UX/UI audit")
    ap.add_argument("--env", default="")
    build(ap.parse_args())
