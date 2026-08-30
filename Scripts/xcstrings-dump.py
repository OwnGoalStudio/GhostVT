#!/usr/bin/env python3
"""Writes a string catalog the way Xcode writes one — sorted keys, two-space
indent, a space before each colon, no trailing newline — so a scripted edit
diffs as the strings it touched and nothing else."""
import json, sys

def dump(obj, indent=0):
    pad = "  " * indent
    if isinstance(obj, dict):
        if not obj:
            return "{\n\n" + pad + "}"
        items = sorted(obj.items(), key=lambda kv: kv[0]) if indent >= 2 else list(obj.items())
        body = ",\n".join(f'{pad}  {json.dumps(k, ensure_ascii=False)} : {dump(v, indent + 1)}' for k, v in items)
        return "{\n" + body + "\n" + pad + "}"
    if isinstance(obj, list):
        return "[\n" + ",\n".join(pad + "  " + dump(v, indent + 1) for v in obj) + "\n" + pad + "]"
    return json.dumps(obj, ensure_ascii=False)

def write(path, catalog, existing_order=None):
    """Keeps Xcode's own order for the keys already in the file (its
    collation is not Python's) and slots new keys in beside their
    case-insensitive neighbours."""
    strings = catalog["strings"]
    order = [k for k in (existing_order or []) if k in strings]
    for k in sorted(k for k in strings if k not in order):
        i = 0
        while i < len(order) and order[i].lower() < k.lower():
            i += 1
        order.insert(i, k)
    catalog["strings"] = {k: strings[k] for k in order}
    with open(path, "w") as f:
        f.write(dump(catalog))

if __name__ == "__main__":
    path = sys.argv[1]
    catalog = json.load(open(path))
    write(path, catalog, list(catalog["strings"].keys()))
