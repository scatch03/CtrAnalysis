"""Regenerate bootstrap.sh — a self-contained installer that writes ./ctr-monitor from heredocs.

    python3 tools/make_bootstrap.py            # from the repo root: ctr-monitor/ → bootstrap.sh
    python3 tools/make_bootstrap.py SRC OUT    # explicit paths

Skips build output, dependencies, run data and caches; ctr_analysis.py is embedded but is
replaced by a ./ctr_analysis.py found next to bootstrap.sh (or in the current folder).
"""
import os, sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
src = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "ctr-monitor"
out = Path(sys.argv[2]) if len(sys.argv) > 2 else root / "bootstrap.sh"
SKIP_DIRS = {"node_modules", "dist", "__pycache__", "data", ".git", ".claude"}
SKIP_FILES = {".DS_Store"}
DELIM = "__CTRMON_EOF__"
files = []
for root, dirs, names in os.walk(src):
    dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
    for n in sorted(names):
        if n in SKIP_FILES:
            continue
        p = Path(root) / n
        rel = p.relative_to(src).as_posix()
        text = p.read_text(encoding="utf-8")
        assert DELIM not in text, rel
        files.append((rel, text))
# embedded script last-but-overridable; everything else first
files.sort(key=lambda f: (f[0] == "ctr_analysis.py", f[0]))

lines = ['#!/usr/bin/env bash',
 '# ctr-monitor bootstrap — writes ./ctr-monitor (Flask + React + Docker) for ctr_analysis.py',
 '#   bash bootstrap.sh        # then: cd ctr-monitor && docker compose up --build -d  → http://localhost:8080',
 '# If ./ctr_analysis.py sits next to this script (or in the current folder) it replaces the embedded v4.1 copy.',
 'set -euo pipefail',
 'DEST="${1:-ctr-monitor}"',
 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
 'if [ -d "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ] && [ "${FORCE:-0}" != "1" ]; then',
 '  echo "refusing to overwrite non-empty $DEST (set FORCE=1 to overwrite its files)" >&2; exit 1',
 'fi',
 'mkdir -p "$DEST"',
 'w() { mkdir -p "$(dirname "$DEST/$1")"; cat > "$DEST/$1"; }',
 '']
for rel, text in files:
    body = text if text.endswith("\n") else text + "\n"
    lines.append(f"w '{rel}' <<'{DELIM}'")
    lines.append(body.rstrip("\n"))
    lines.append(DELIM)
lines += ['',
 'for cand in "$HERE/ctr_analysis.py" "$PWD/ctr_analysis.py"; do',
 '  if [ -f "$cand" ] && [ "$(cd "$(dirname "$cand")" && pwd)" != "$(cd "$DEST" && pwd)" ]; then',
 '    cp "$cand" "$DEST/ctr_analysis.py"; echo "using analysis script: $cand"; break',
 '  fi',
 'done',
 'echo "wrote $(cd "$DEST" && pwd)"',
 'echo "next: cd $DEST && docker compose up --build -d   # → http://localhost:8080"',
 '']
out.write_text("\n".join(lines), encoding="utf-8")
os.chmod(out, 0o755)
print(f"{len(files)} files → {out} ({out.stat().st_size // 1024} KB)")
