"""
Structural validator for the helm/the-redemption chart.

This environment has no live AWS credentials and no network access to
get.helm.sh, so a real 'helm lint'/'helm template' could not be run here -
see the README's "A note on how this chart was validated" section. This
script is the next best thing: it checks the things most likely to be
wrong in a hand-written chart without actually implementing a Go-template
engine.

Run 'helm lint helm/the-redemption' yourself as the very first step after
cloning this repo - it supersedes everything this script checks.
"""
import re
import sys
import yaml
from pathlib import Path

CHART_DIR = Path(__file__).parent / "helm" / "the-redemption"
TEMPLATES_DIR = CHART_DIR / "templates"
errors = []


def get_path(d, path):
    cur = d
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


print("=== Loading values.yaml and Chart.yaml ===")
values = yaml.safe_load((CHART_DIR / "values.yaml").read_text())
chart_meta = yaml.safe_load((CHART_DIR / "Chart.yaml").read_text())
print(f"  Chart: {chart_meta['name']} v{chart_meta['version']}")
print(f"  values.yaml: {len(values)} top-level keys")

print("\n=== Checking every .Values.x.y reference resolves ===")
all_refs = set()
for f in sorted(TEMPLATES_DIR.glob("*.yaml")):
    content = f.read_text()
    for m in re.finditer(r"\.Values\.([a-zA-Z0-9_.]+)", content):
        all_refs.add((f.name, m.group(1)))

for fname, path in sorted(all_refs):
    val = get_path(values, path)
    if val is None and get_path(values, path) is None and path not in str(values):
        # double-check: a literal None value is valid, only a missing KEY is an error
        cur = values
        missing = False
        for part in path.split("."):
            if not isinstance(cur, dict) or part not in cur:
                missing = True
                break
            cur = cur[part]
        if missing:
            errors.append(f"{fname}: .Values.{path} not found in values.yaml")

print(f"  Checked {len(all_refs)} references, {len([e for e in errors if 'not found' in e])} missing")

print("\n=== Checking balanced {{- if }} / {{- end }} blocks ===")
for f in sorted(TEMPLATES_DIR.glob("*.yaml")) + [TEMPLATES_DIR / "_helpers.tpl"]:
    content = f.read_text()
    opens = len(re.findall(r"\{\{-?\s*(if |define )", content))
    closes = len(re.findall(r"\{\{-?\s*end\s*-?\}\}", content))
    status = "OK" if opens == closes else "MISMATCH"
    print(f"  {status:9s} {f.name:25s} if/define={opens}  end={closes}")
    if opens != closes:
        errors.append(f"{f.name}: unbalanced if/end ({opens} opens vs {closes} closes)")

print("\n=== Checking include calls resolve to defined helper templates ===")
helpers_content = (TEMPLATES_DIR / "_helpers.tpl").read_text()
defined = set(re.findall(r'define\s+"([^"]+)"', helpers_content))
print(f"  Defined: {sorted(defined)}")
for f in sorted(TEMPLATES_DIR.glob("*.yaml")):
    content = f.read_text()
    for m in re.finditer(r'include\s+"([^"]+)"', content):
        name = m.group(1)
        if name not in defined:
            errors.append(f"{f.name}: include \"{name}\" has no matching define")

print("\n=== Checking non-templated YAML (Chart.yaml, values.yaml) parses ===")
for f in [CHART_DIR / "Chart.yaml", CHART_DIR / "values.yaml"]:
    try:
        yaml.safe_load(f.read_text())
        print(f"  OK   {f.name}")
    except yaml.YAMLError as e:
        errors.append(f"{f.name}: {e}")
        print(f"  FAIL {f.name}: {e}")

print("\n=== Checking key cross-references inside values.yaml itself ===")
baseline_replicas = get_path(values, "baseline.replicas")
keda_min = get_path(values, "keda.minReplicas")
keda_max = get_path(values, "keda.maxReplicas")
print(f"  baseline.replicas={baseline_replicas}  keda.minReplicas={keda_min}  keda.maxReplicas={keda_max}")
if keda_min != 0:
    errors.append("keda.minReplicas should be 0 - burst tier should scale to zero outside spikes")
if keda_max < baseline_replicas * 9:
    errors.append("keda.maxReplicas may be too low to absorb a 10x spike on top of the baseline floor")

print("\n" + "=" * 60)
if errors:
    print(f"{len(errors)} ISSUE(S) FOUND:")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
else:
    print("ALL CHECKS PASSED - chart is structurally consistent.")
    print("(Run 'helm lint helm/the-redemption' for full template-engine validation.)")
