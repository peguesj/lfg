#!/usr/bin/env python3
"""STFU Report Generator - Creates interactive HTML from STFU JSON data."""

import json
import os
import sys


def generate_html(data: dict, lfg_dir: str) -> str:
    theme = open(f"{lfg_dir}/lib/theme.css").read()
    uijs = open(f"{lfg_dir}/lib/ui.js").read()

    meta = data.get("meta", {})
    summary = data.get("summary", {})
    projects = data.get("projects", [])
    duplicates = data.get("duplicates", [])
    relationships = data.get("relationships", [])
    clusters = data.get("clusters", [])
    conflicts = data.get("version_conflicts", [])
    fingerprints = data.get("fingerprints", {})
    code_dupes = data.get("code_duplicates", [])
    lib_candidates = data.get("library_candidates", [])
    env_groups = data.get("environment_groups", [])
    ai_analysis = data.get("ai_analysis", {})

    # Executive summary
    savings = summary.get("estimated_savings_mb", 0)

    # Build duplicate rows
    dupe_rows = ""
    for d in duplicates[:20]:
        score = round(d.get("jaccard_similarity", 0) * 100)
        color = "#ff4d6a" if score > 80 else "#ff8c42"
        shared = len(d.get("shared_deps", []))
        dupe_rows += f'''<tr data-tip="{', '.join(d.get('shared_deps', [])[:8])}">
            <td class="name">{d["project_a"]}</td>
            <td class="name">{d["project_b"]}</td>
            <td class="pct" style="color:{color}">{score}%</td>
            <td class="meta">{shared} deps</td>
            <td class="action-cell"><button class="action-btn-sm" onclick="LFG.exec('~/tools/@yj/lfg/lfg stfu merge-check {d["project_a"]} {d["project_b"]}', function(o){{LFG.toast(o.substring(0,200),{{type:\\'info\\',duration:5000}})}})">Check</button></td>
        </tr>'''

    # Relationship rows
    rel_rows = ""
    for r in relationships[:25]:
        score = round(r.get("combined_score", r.get("jaccard_similarity", 0)) * 100)
        dep_sim = round(r.get("jaccard_similarity", 0) * 100)
        struct_sim = round(r.get("structural_similarity", 0) * 100)
        rel_rows += f'''<tr data-tip="Dep: {dep_sim}% Struct: {struct_sim}%">
            <td class="name">{r["project_a"]}</td>
            <td class="name">{r["project_b"]}</td>
            <td class="bar-cell"><div class="bar-track"><div class="bar-fill" style="width:{score}%;background:#c084fc"></div></div></td>
            <td class="pct">{score}%</td>
            <td class="meta">{len(r.get('shared_deps', []))} shared</td>
        </tr>'''

    # Cluster cards
    cluster_html = ""
    for i, c in enumerate(clusters[:10]):
        projects_html = " ".join(
            f'<span class="ai-pill" style="background:#06d6a020;color:#06d6a0;border:1px solid #06d6a033">{p}</span>'
            for p in c
        )
        cluster_html += f'''<div style="margin-bottom:12px;padding:12px 14px;background:#1c1c22;border:1px solid #2a2a34;border-radius:8px;border-left:3px solid #06d6a0">
            <div style="font-size:10px;text-transform:uppercase;letter-spacing:0.8px;color:#06d6a0;margin-bottom:6px">Cluster {i+1} ({len(c)} projects)</div>
            <div style="display:flex;flex-wrap:wrap;gap:6px">{projects_html}</div>
        </div>'''

    # Code duplicate rows
    code_dupe_rows = ""
    for cd in code_dupes[:15]:
        sim = round(cd.get("similarity", 0) * 100)
        cat = cd.get("pattern_category", "custom")
        cat_colors = {"auth": "#ff4d6a", "error_handling": "#ff8c42", "cors": "#ffd166", "validation": "#4a9eff", "custom": "#6b6b78"}
        cc = cat_colors.get(cat, "#6b6b78")
        # Shorten paths
        fa = cd["file_a"].replace(os.path.expanduser("~/Developer/"), "")
        fb = cd["file_b"].replace(os.path.expanduser("~/Developer/"), "")
        code_dupe_rows += f'''<tr data-tip="{fa} vs {fb}">
            <td class="name">{cd["project_a"]}</td>
            <td class="name">{cd["project_b"]}</td>
            <td><span class="cat" style="color:{cc}">{cat}</span></td>
            <td class="pct">{sim}%</td>
            <td class="meta">{cd.get("line_count", 0)} lines</td>
        </tr>'''

    # Library candidate cards
    lib_html = ""
    type_colors = {
        "ui-components": "#4a9eff", "auth": "#ff4d6a", "api-client": "#ffd166",
        "middleware": "#ff8c42", "testing-config": "#06d6a0", "build-config": "#c084fc",
    }
    for lc in lib_candidates:
        lc_color = type_colors.get(lc["lib_type"], "#6b6b78")
        projs = ", ".join(lc["source_projects"][:6])
        lib_html += f'''<div style="margin-bottom:10px;padding:12px 14px;background:#1c1c22;border:1px solid #2a2a34;border-radius:8px;border-left:3px solid {lc_color}">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
                <span style="font-weight:700;color:#fff;font-size:13px">{lc["name"]}</span>
                <span class="ai-pill" style="background:{lc_color}20;color:{lc_color};border:1px solid {lc_color}33">{lc["lib_type"]}</span>
            </div>
            <div style="font-size:11px;color:#6b6b78;margin-bottom:4px">Sources: {projs}</div>
            <div style="display:flex;gap:16px;font-size:10px;color:#4a4a56">
                <span>~{lc["estimated_dedup_savings_mb"]:.0f} MB savings</span>
                <span>~{lc["effort_hours"]}h effort</span>
                <span>Priority: {"!" * lc["priority"]}</span>
            </div>
        </div>'''

    # Environment group cards
    env_html = ""
    for eg in env_groups:
        compat = round(eg["compatibility_score"] * 100)
        projs = ", ".join(eg["projects"][:8])
        conflict_count = len(eg.get("conflicts", []))
        env_html += f'''<div style="margin-bottom:10px;padding:12px 14px;background:#1c1c22;border:1px solid #2a2a34;border-radius:8px;border-left:3px solid #ff8c42">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
                <span style="font-weight:700;color:#fff;font-size:12px">{eg["ecosystem"].upper()} Group ({len(eg["projects"])} projects)</span>
                <span style="font-size:11px;color:{'#06d6a0' if compat > 80 else '#ff8c42'}">{compat}% compatible</span>
            </div>
            <div style="font-size:11px;color:#6b6b78;margin-bottom:4px">{projs}</div>
            <div style="display:flex;gap:16px;font-size:10px;color:#4a4a56">
                <span>~{eg["savings_estimate_mb"]:.0f} MB potential savings</span>
                <span>{conflict_count} version conflicts</span>
                <span>{len(eg.get('shared_deps', []))} shared deps</span>
            </div>
        </div>'''

    # Template groups
    tpl_html = ""
    for tpl, projs in fingerprints.get("template_groups", {}).items():
        tpl_html += f'''<div style="margin-bottom:8px;padding:8px 12px;background:#1c1c22;border:1px solid #2a2a34;border-radius:6px">
            <span style="font-size:11px;color:#e879f9;font-weight:600">{tpl}</span>
            <span style="font-size:10px;color:#6b6b78"> - {len(projs)} projects: {', '.join(projs)}</span>
        </div>'''

    # AI insights
    ai_html = ""
    for name, info in list(ai_analysis.items())[:12]:
        purpose = info.get("purpose", "Unknown")
        category = info.get("category", "other")
        risk = info.get("merge_risk", "unknown")
        risk_color = {"low": "#06d6a0", "medium": "#ffd166", "high": "#ff4d6a"}.get(risk, "#6b6b78")
        ai_html += f'''<tr>
            <td class="name">{name}</td>
            <td style="font-size:11px;color:#a0a0b0">{purpose[:60]}</td>
            <td><span class="ai-pill">{category}</span></td>
            <td style="color:{risk_color};font-size:11px">{risk}</td>
        </tr>'''

    html = f'''<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>{theme}
.stfu-nav {{ display:flex; gap:8px; margin:12px 0; flex-wrap:wrap; }}
.stfu-nav a {{ padding:6px 14px; border:1px solid #2a2a34; border-radius:6px; font-size:11px; color:#6b6b78; cursor:pointer; transition:all 0.15s; }}
.stfu-nav a:hover, .stfu-nav a.active {{ border-color:#e879f9; color:#e879f9; background:#e879f910; }}
.stfu-section {{ display:none; }}
.stfu-section.active {{ display:block; }}
.action-btn-sm {{ padding:4px 10px; border:1px solid #c084fc; border-radius:4px; background:transparent; color:#c084fc; font-size:10px; cursor:pointer; font-family:inherit; }}
.action-btn-sm:hover {{ background:#c084fc15; }}
</style>
</head><body>
  <div class="header">
    <h1><span class="brand">lfg</span> stfu <span class="dim">Source Tree Forensics & Unification</span></h1>
    <span class="meta">{meta.get('timestamp', '')}</span>
  </div>
  <div class="summary">
    <div class="stat" data-tip="Total projects analyzed"><span class="label">Projects</span><span class="value">{summary.get('total_projects', 0)}</span></div>
    <div class="stat" data-tip="Near-identical project pairs"><span class="label">Duplicates</span><span class="value warn">{summary.get('duplicate_pairs', 0)}</span></div>
    <div class="stat" data-tip="Related project pairs"><span class="label">Relationships</span><span class="value">{summary.get('relationship_pairs', 0)}</span></div>
    <div class="stat" data-tip="Project clusters"><span class="label">Clusters</span><span class="value accent">{summary.get('cluster_count', 0)}</span></div>
    <div class="stat" data-tip="Code pattern duplicates"><span class="label">Code Dupes</span><span class="value" style="color:#ff8c42">{summary.get('code_duplicate_files', 0)}</span></div>
    <div class="stat" data-tip="Shared library opportunities"><span class="label">Libraries</span><span class="value" style="color:#4a9eff">{summary.get('library_candidates', 0)}</span></div>
    <div class="stat" data-tip="Estimated disk savings"><span class="label">Savings</span><span class="value good">{savings:.0f} MB</span></div>
  </div>

  <div class="stfu-nav">
    <a class="active" onclick="showSection('dupes', this)">Duplicates</a>
    <a onclick="showSection('rels', this)">Relationships</a>
    <a onclick="showSection('clusters', this)">Clusters</a>
    <a onclick="showSection('codedupes', this)">Code Patterns</a>
    <a onclick="showSection('libs', this)">Libraries</a>
    <a onclick="showSection('envs', this)">Environments</a>
    <a onclick="showSection('templates', this)">Templates</a>
    {'<a onclick="showSection(\\\'ai\\\', this)">AI Insights</a>' if ai_analysis else ''}
  </div>

  <div id="sec-dupes" class="stfu-section active">
    <div class="guidance" style="border-left-color:#ff4d6a"><strong>Duplicates</strong> - Project pairs with &gt;70% dependency overlap. Strong candidates for merging or archival.</div>
    {'<table><thead><tr><th>Project A</th><th>Project B</th><th class="r">Overlap</th><th>Shared</th><th></th></tr></thead><tbody>' + dupe_rows + '</tbody></table>' if dupe_rows else '<div class="empty-state">No duplicates found (>70% overlap threshold)</div>'}
  </div>

  <div id="sec-rels" class="stfu-section">
    <div class="guidance" style="border-left-color:#c084fc"><strong>Relationships</strong> - All project pairs with measurable similarity (dep + structural + code).</div>
    {'<table><thead><tr><th>Project A</th><th>Project B</th><th>Combined</th><th class="r">Score</th><th>Deps</th></tr></thead><tbody>' + rel_rows + '</tbody></table>' if rel_rows else '<div class="empty-state">No relationships found</div>'}
  </div>

  <div id="sec-clusters" class="stfu-section">
    <div class="guidance" style="border-left-color:#06d6a0"><strong>Coalescence Clusters</strong> - Groups of projects that could share infrastructure, environments, or be merged into monorepos.</div>
    {cluster_html or '<div class="empty-state">No clusters found</div>'}
  </div>

  <div id="sec-codedupes" class="stfu-section">
    <div class="guidance" style="border-left-color:#ff8c42"><strong>Code Duplicates</strong> - Middleware, handlers, and utilities with high content similarity across projects.</div>
    {'<table><thead><tr><th>Project A</th><th>Project B</th><th>Pattern</th><th class="r">Similarity</th><th>Lines</th></tr></thead><tbody>' + code_dupe_rows + '</tbody></table>' if code_dupe_rows else '<div class="empty-state">No code duplicates found</div>'}
  </div>

  <div id="sec-libs" class="stfu-section">
    <div class="guidance" style="border-left-color:#4a9eff"><strong>Library Candidates</strong> - Recommended shared packages to extract from duplicate code and dep overlap.</div>
    {lib_html or '<div class="empty-state">No library candidates identified</div>'}
  </div>

  <div id="sec-envs" class="stfu-section">
    <div class="guidance" style="border-left-color:#ff8c42"><strong>Environment Groups</strong> - Projects with compatible dependencies that could share node_modules/venvs.</div>
    {env_html or '<div class="empty-state">No environment consolidation opportunities found</div>'}
  </div>

  <div id="sec-templates" class="stfu-section">
    <div class="guidance" style="border-left-color:#e879f9"><strong>Template Groups</strong> - Projects built from the same scaffolding or boilerplate.</div>
    {tpl_html or '<div class="empty-state">No template groups detected</div>'}
  </div>

  <div id="sec-ai" class="stfu-section">
    <div class="guidance" style="border-left-color:#ffd166"><strong>AI Insights</strong> - Semantic analysis of project purpose and merge risk.</div>
    {'<table><thead><tr><th>Project</th><th>Purpose</th><th>Category</th><th>Merge Risk</th></tr></thead><tbody>' + ai_html + '</tbody></table>' if ai_html else '<div class="empty-state">AI analysis not available. Check: lfg ai config show</div>'}
  </div>

  <div class="footer">lfg stfu v2.0.0 - Source Tree Forensics & Unification | {summary.get('total_projects', 0)} projects analyzed</div>

  <script>{uijs}
  LFG.init({{
    module: "stfu", context: "Source Tree Forensics",
    moduleVersion: "2.0.0",
    welcome: "{summary.get('total_projects', 0)} projects, {summary.get('duplicate_pairs', 0)} duplicates, ~{savings:.0f} MB savings"
  }});
  function showSection(id, el) {{
    document.querySelectorAll('.stfu-section').forEach(function(s) {{ s.classList.remove('active'); }});
    document.querySelectorAll('.stfu-nav a').forEach(function(a) {{ a.classList.remove('active'); }});
    document.getElementById('sec-' + id).classList.add('active');
    if (el) el.classList.add('active');
  }}
  </script>
</body></html>'''
    return html


if __name__ == "__main__":
    output_path = sys.argv[1] if len(sys.argv) > 1 else ""
    data = json.load(sys.stdin)
    lfg_dir = os.environ.get("LFG_DIR", os.path.expanduser("~/tools/@yj/lfg"))
    html = generate_html(data, lfg_dir)
    if output_path:
        with open(output_path, "w") as f:
            f.write(html)
    else:
        print(html)
