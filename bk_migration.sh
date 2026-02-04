#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
DRY_RUN="${DRY_RUN:-false}"
YQ_BIN="${YQ_BIN:-yq}"

POLARIS_TASK_REGEX='^SynopsysPolaris@'

PIPELINE_PATTERNS=(
  -name "azure-pipelines.yml" -o
  -name "azure-pipelines.yaml" -o
  -name "*pipeline*.yml" -o
  -name "*pipeline*.yaml" -o
  -path "*/.azuredevops/*.yml" -o
  -path "*/.azuredevops/*.yaml" -o
  -path "*/.pipelines/*.yml" -o
  -path "*/.pipelines/*.yaml"
)

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing command: $1" >&2; exit 1; }; }
need_cmd "$YQ_BIN"
need_cmd find
need_cmd python3

# Replacement stage content (YAML list of stages)
STAGE_TMP="$(mktemp)"
cat > "$STAGE_TMP" <<'YAML'
- stage: BlackduckCoverityOnPolaris
  displayName: Blackduck + Coverity on Polaris
  jobs:
  - job: polaris_scan
    displayName: Polaris scan
    steps:
    - task: SynopsysPolaris@1
      inputs:
        polarisService: 'test01'
        polarisCommand: 'polaris'
        waitForIssues: true
        populateChangeSetFile: true

    - task: BlackduckCoverityOnPolaris@2
      inputs:
        polarisService: 'test1'
        polarisCommand: 'polaris'
        waitForIssues: true
        populateChangeSetFile: true
YAML

cleanup() { rm -f "$STAGE_TMP"; }
trap cleanup EXIT

echo "Scanning: $ROOT_DIR"
echo "DRY_RUN=$DRY_RUN"
echo "yq version: $("$YQ_BIN" --version 2>&1 || true)"
echo

mapfile -t files < <(find "$ROOT_DIR" -type f \( "${PIPELINE_PATTERNS[@]}" \) 2>/dev/null)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No pipeline YAML files found."
  exit 0
fi

echo "Found ${#files[@]} candidate pipeline file(s):"
printf ' - %s\n' "${files[@]}"
echo

updated=0
skipped=0

for f in "${files[@]}"; do
  echo "----"
  echo "Checking file: $f"

  echo "Debug task values found in file:"
  "$YQ_BIN" e '.. | select(tag=="!!map") | .task? | select(.)' "$f" 2>&1 || true

  # Detect Polaris task anywhere (works with yq v4)
  if ! POLARIS_TASK_REGEX="$POLARIS_TASK_REGEX" "$YQ_BIN" e -e \
      '([.. | select(tag=="!!map") | .task? | select(.) | select(test(strenv(POLARIS_TASK_REGEX)))] | length) > 0' \
      "$f" >/dev/null 2>&1; then
    echo "Detection result: NO MATCH -> skipping"
    ((++skipped)) || true
    continue
  fi

  echo "Detection result: MATCH -> processing"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: would update $f"
    ((++updated)) || true
    continue
  fi

  cp -p "$f" "$f.bak"

  # Do the actual transformation in python (because yq doesn't support if/else conditionals)
  POLARIS_TASK_REGEX="$POLARIS_TASK_REGEX" REPL_STAGE_FILE="$STAGE_TMP" python3 - "$f" <<'PY'
import os, re, sys

try:
    import yaml
except Exception as e:
    print("ERROR: Python module 'yaml' (PyYAML) is required but not available.", file=sys.stderr)
    print("Install it on the agent: pip install pyyaml", file=sys.stderr)
    raise

path = sys.argv[1]
regex = re.compile(os.environ["POLARIS_TASK_REGEX"])
repl_stage_file = os.environ["REPL_STAGE_FILE"]

def contains_polaris(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "task" and isinstance(v, str) and regex.search(v):
                return True
            if contains_polaris(v):
                return True
    elif isinstance(obj, list):
        return any(contains_polaris(i) for i in obj)
    return False

def remove_polaris_steps(steps):
    out = []
    for s in steps or []:
        if isinstance(s, dict) and isinstance(s.get("task"), str) and regex.search(s["task"]):
            continue
        out.append(s)
    return out

def mk_legacy_stage(name, display, job, steps):
    return {
        "stage": name,
        "displayName": display,
        "jobs": [{
            "job": job,
            "displayName": display,
            "steps": steps
        }]
    }

with open(path, "r", encoding="utf-8") as f:
    doc = yaml.safe_load(f) or {}

with open(repl_stage_file, "r", encoding="utf-8") as f:
    repl_stages = yaml.safe_load(f) or []
    if not isinstance(repl_stages, list):
        raise ValueError("Replacement stage file must be a YAML list of stages")

# CASE 1: stages-based pipeline
if isinstance(doc.get("stages"), list):
    stages = doc["stages"]
    matches = [i for i, st in enumerate(stages) if contains_polaris(st)]
    if not matches:
        # nothing to do
        sys.exit(0)
    insert_at = matches[0]
    kept = [st for st in stages if not contains_polaris(st)]
    doc["stages"] = kept[:insert_at] + repl_stages + kept[insert_at:]

# CASE 2: steps-only pipeline
elif isinstance(doc.get("steps"), list):
    steps = doc["steps"]
    first_idx = None
    for i, s in enumerate(steps):
        if isinstance(s, dict) and isinstance(s.get("task"), str) and regex.search(s["task"]):
            first_idx = i
            break
    if first_idx is None:
        sys.exit(0)

    pre = remove_polaris_steps(steps[:first_idx])
    post = remove_polaris_steps(steps[first_idx+1:])

    doc.pop("steps", None)
    new_stages = []
    if pre:
        new_stages.append(mk_legacy_stage("LegacyPre", "Legacy steps (pre)", "legacy_pre", pre))
    new_stages.extend(repl_stages)
    if post:
        new_stages.append(mk_legacy_stage("LegacyPost", "Legacy steps (post)", "legacy_post", post))
    doc["stages"] = new_stages

else:
    # neither stages nor steps at root
    sys.exit(0)

with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(doc, f, sort_keys=False)
PY

  echo "Updated. Backup saved: $f.bak"
  ((++updated)) || true
done

echo
echo "Done."
echo "Updated: $updated"
echo "Skipped: $skipped"
