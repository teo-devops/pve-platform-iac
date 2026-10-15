#!/usr/bin/env python3
"""check-docs-links.py — enlaces internos rotos en la documentacion (CI: pr-validate.yml).

Revisa cada enlace relativo [texto](ruta) y [texto](ruta#ancla) de los .md del repo:
la ruta tiene que existir y, si lleva ancla, el documento destino tiene que tener
un encabezado que genere ese ancla (como lo calcula GitHub). Sin red: los enlaces
http(s) no se comprueban.
"""
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
SKIP = (".git", ".terraform", "node_modules")


def slug(h):
    """Ancla de GitHub para un encabezado: minusculas, sin puntuacion, espacios -> '-'."""
    h = re.sub(r"[`*]", "", h.strip().lower())
    h = "".join(c for c in h if c.isalnum() or c in " -_" or unicodedata.category(c).startswith("L"))
    return h.replace(" ", "-")


def anchors(path, cache={}):
    if path not in cache:
        text, out, seen, fence = open(path, encoding="utf-8").read(), set(), {}, False
        for line in text.splitlines():
            if line.startswith("```"):
                fence = not fence
            m = None if fence else re.match(r"^#{1,6}\s+(.*?)\s*#*$", line)
            if m:
                s = slug(m.group(1))
                n = seen.get(s, 0)
                out.add(s if n == 0 else f"{s}-{n}")
                seen[s] = n + 1
        cache[path] = out
    return cache[path]


bad = []
for dirpath, dirs, files in os.walk(ROOT):
    dirs[:] = [d for d in dirs if d not in SKIP]
    for f in files:
        if not f.endswith(".md"):
            continue
        src = os.path.join(dirpath, f)
        fence = False
        for n, line in enumerate(open(src, encoding="utf-8"), 1):
            if line.startswith("```"):
                fence = not fence
            if fence:
                continue
            for target in LINK.findall(line):
                if re.match(r"^[a-z]+:", target) or target.startswith("<"):
                    continue
                path, _, anchor = target.partition("#")
                dest = os.path.normpath(os.path.join(dirpath, path)) if path else src
                rel = os.path.relpath(src, ROOT)
                if not os.path.exists(dest):
                    bad.append(f"{rel}:{n}: {target} -> no existe")
                elif anchor and dest.endswith(".md") and anchor not in anchors(dest):
                    bad.append(f"{rel}:{n}: {target} -> no hay encabezado '#{anchor}'")
for b in bad:
    print("✗ " + b)
if bad:
    sys.exit(f"{len(bad)} enlace(s) roto(s) en la documentacion.")
print("✓ Enlaces internos de la documentacion correctos.")
