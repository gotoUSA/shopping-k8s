"""Compare `helm template` output of chart/ with manifests/, object by object.

Usage (from the repository root):
    helm template shopping chart -n shopping > rendered.yaml
    python tests/helm-template-diff.py rendered.yaml

Prints objects that exist on one side only and the fields that differ.
Comments and key order are ignored (both sides are parsed as YAML).
"""

import glob
import sys

import yaml


def key(doc):
    return (doc["kind"], doc["metadata"].get("namespace"), doc["metadata"]["name"])


def diff(x, y, path=""):
    if isinstance(x, dict) and isinstance(y, dict):
        for k in sorted(set(x) | set(y)):
            if k not in x:
                print("  +", f"{path}.{k}", "=", y[k])
            elif k not in y:
                print("  -", f"{path}.{k}")
            else:
                diff(x[k], y[k], f"{path}.{k}")
    elif isinstance(x, list) and isinstance(y, list) and len(x) == len(y):
        for i, (u, v) in enumerate(zip(x, y)):
            diff(u, v, f"{path}[{i}]")
    elif x != y:
        print("  ~", path, ":", x, "->", y)


manifests = {}
for f in sorted(glob.glob("manifests/[0-9]*.yaml")):
    with open(f, encoding="utf-8") as fh:
        for doc in yaml.safe_load_all(fh):
            if doc:
                manifests[key(doc)] = doc
with open(sys.argv[1], encoding="utf-8") as fh:
    rendered = {key(d): d for d in yaml.safe_load_all(fh) if d}

print("only in manifests:", sorted(set(manifests) - set(rendered)))
print("only in chart:", sorted(set(rendered) - set(manifests)))
same = 0
for k in sorted(set(manifests) & set(rendered)):
    if manifests[k] == rendered[k]:
        same += 1
    else:
        print(k)
        diff(manifests[k], rendered[k])
print("identical:", same, "of", len(set(manifests) & set(rendered)))
