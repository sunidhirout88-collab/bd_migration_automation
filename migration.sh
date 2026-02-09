#!/usr/bin/env bash
set -euo pipefail

# ---------- Resolve script location safely ----------
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

echo "SCRIPT PATH: ${SCRIPT_PATH}"
echo "SCRIPT HASH: $(sha256sum "${SCRIPT_PATH}" | awk '{print $1}')"

# ---------- Move to folder containing azure-pipelines.yml ----------
if [[ -f "${SCRIPT_DIR}/target/azure-pipelines.yml" ]]; then
  cd "${SCRIPT_DIR}/target"
elif [[ -f "${SCRIPT_DIR}/azure-pipelines.yml" ]]; then
  cd "${SCRIPT_DIR}"
else
  echo "ERROR: Cannot locate azure-pipelines.yml in ${SCRIPT_DIR} or ${SCRIPT_DIR}/target"
  exit 1
fi

PIPELINE_FILE="azure-pipelines.yml"
echo "PWD: $(pwd)"
echo "Editing: ${PIPELINE_FILE}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required on the agent."
  exit 1
fi

# Backup
cp -p "${PIPELINE_FILE}" "${PIPELINE_FILE}.bak"
echo "Backup saved as ${PIPELINE_FILE}.bak"

# Install ruamel.yaml (preserves comments/format much better than plain PyYAML)
python3 -m pip -q install --user ruamel.yaml >/dev/null 2>&1 || {
  echo "ERROR: failed to install ruamel.yaml (pip)."
  exit 1
}

python3 - <<'PY'
import re
from copy import deepcopy
from ruamel.yaml import YAML

PIPELINE_FILE = "azure-pipelines.yml"

COV_RE = re.compile(r"\bcov-", re.IGNORECASE)
COVERITY_RE = re.compile(r"\bcoverity\b", re.IGNORECASE)
BD_RE = re.compile(r"(synopsys detect|detect\.sh|blackduck\.url|black duck)", re.IGNORECASE)

BD_VARS = {
    "BLACKDUCK_URL": "https://blackduck.mycompany.com",
    "BD_PROJECT": "my-app",
    "BD_VERSION": "$(Build.SourceBranchName)",
    "DETECT_VERSION": "latest",
}

BD_STEPS = [
    {
        "task": "JavaToolInstaller@0",
        "displayName": "Use Java 11",
        "inputs": {
            "versionSpec": "11",
            "jdkArchitectureOption": "x64",
            "jdkSourceOption": "PreInstalled",
        },
    },
    {
        "bash": "\n".join([
            "set -euo pipefail",
            "",
            'echo "Downloading Synopsys Detect..."',
            "curl -fsSL -o detect.sh https://detect.synopsys.com/detect.sh",
            "chmod +x detect.sh",
            "",
            'echo "Running Black Duck scan via Synopsys Detect..."',
            "./detect.sh \\",
            '  --blackduck.url="$(BLACKDUCK_URL)" \\',
            '  --blackduck.api.token="$(BLACKDUCK_API_TOKEN)" \\',
            '  --detect.project.name="$(BD_PROJECT)" \\',
            '  --detect.project.version.name="$(BD_VERSION)" \\',
            '  --detect.source.path="$(Build.SourcesDirectory)" \\',
            "  --detect.tools=DETECTOR,SIGNATURE_SCAN \\",
            "  --detect.detector.search.depth=6 \\",
            "  --detect.wait.for.results=true \\",
            "  --detect.notices.report=true \\",
            "  --detect.risk.report.pdf=true \\",
            "  --logging.level.com.synopsys.integration=INFO \\",
            "  --detect.cleanup=true",
        ]),
        "displayName": "Black Duck Scan (Synopsys Detect)",
        "env": {"BLACKDUCK_API_TOKEN": "$(BLACKDUCK_API_TOKEN)"},
    },
    {
        "task": "PublishBuildArtifacts@1",
        "displayName": "Publish Black Duck Reports",
        "inputs": {
            "PathtoPublish": "$(Build.SourcesDirectory)/blackduck",
            "ArtifactName": "blackduck-reports",
        },
        "condition": "succeededOrFailed()",
    },
]

def step_text(step):
    if not isinstance(step, dict):
        return ""
    parts = []
    for k in ("displayName","task","bash","script","pwsh","powershell"):
        v = step.get(k)
        if isinstance(v, str):
            parts.append(v)
    inputs = step.get("inputs", {})
    if isinstance(inputs, dict):
        for k, v in inputs.items():
            parts.append(f"{k}={v}")
    return "\n".join(parts).lower()

def is_coverity_step(step):
    t = step_text(step)
    if COV_RE.search(t) or COVERITY_RE.search(t):
        return True
    inputs = step.get("inputs", {}) if isinstance(step, dict) else {}
    if isinstance(inputs, dict):
        art = str(inputs.get("artifactName", inputs.get("ArtifactName",""))).lower()
        pth = str(inputs.get("pathToPublish", inputs.get("PathtoPublish",""))).lower()
        if "coverity" in art or "coverity" in pth or "$(coverity_" in pth:
            return True
    return False

def has_blackduck(pipeline):
    return any(BD_RE.search(step_text(s)) for s in (pipeline.get("steps") or []))

def coverity_bash_count(pipeline):
    c = 0
    for s in pipeline.get("steps") or []:
        if isinstance(s, dict) and isinstance(s.get("bash"), str) and COV_RE.search(s["bash"]):
            c += 1
    return c

def detect_bash_count(pipeline):
    c = 0
    for s in pipeline.get("steps") or []:
        if isinstance(s, dict) and isinstance(s.get("bash"), str) and re.search(r"detect\.sh", s["bash"], re.I):
            c += 1
    return c

def drop_coverity_vars(vars_node):
    if vars_node is None:
        return None
    if isinstance(vars_node, dict):
        return {k:v for k,v in vars_node.items() if not str(k).startswith("COVERITY_")}
    if isinstance(vars_node, list):
        out=[]
        for item in vars_node:
            if isinstance(item, dict) and str(item.get("name","")).startswith("COVERITY_"):
                continue
            out.append(item)
        return out
    return vars_node

def merge_bd_vars(vars_node):
    if vars_node is None:
        return deepcopy(BD_VARS)
    if isinstance(vars_node, dict):
        merged = dict(vars_node)
        merged.update(BD_VARS)
        return merged
    if isinstance(vars_node, list):
        out = list(vars_node)
        existing = {i.get("name") for i in out if isinstance(i, dict)}
        for k,v in BD_VARS.items():
            if k not in existing:
                out.append({"name": k, "value": v})
        return out
    return vars_node

def inject_bd_steps(steps):
    steps = steps or []
    # insert after first step (usually checkout)
    if len(steps) >= 1:
        return [steps[0]] + deepcopy(BD_STEPS) + steps[1:]
    return deepcopy(BD_STEPS)

yaml = YAML()
yaml.preserve_quotes = True
yaml.indent(mapping=2, sequence=2, offset=0)

with open(PIPELINE_FILE, "r", encoding="utf-8") as f:
    pipeline = yaml.load(f)

if not isinstance(pipeline, dict):
    raise SystemExit("ERROR: pipeline root is not a YAML map/object.")

print("Coverity bash-step count BEFORE:", coverity_bash_count(pipeline))
print("Detect bash-step count BEFORE:", detect_bash_count(pipeline))

# variables: remove coverity + merge BD
pipeline["variables"] = merge_bd_vars(drop_coverity_vars(pipeline.get("variables")))

# steps: remove coverity
steps = pipeline.get("steps") or []
if not isinstance(steps, list):
    steps = []
steps = [s for s in steps if not (isinstance(s, dict) and is_coverity_step(s))]
pipeline["steps"] = steps

# inject BD steps if missing
if not has_blackduck(pipeline):
    pipeline["steps"] = inject_bd_steps(pipeline["steps"])

print("Coverity bash-step count AFTER:", coverity_bash_count(pipeline))
print("Detect bash-step count AFTER:", detect_bash_count(pipeline))

with open(PIPELINE_FILE, "w", encoding="utf-8") as f:
    yaml.dump(pipeline, f)

print("✅ Migration complete:", PIPELINE_FILE)
PY

echo "Post-check Coverity (should be EMPTY):"
if grep -nE '^[^#]*\bcov-' -n "${PIPELINE_FILE}"; then
  echo "❌ Coverity still present"
  exit 1
else
  echo "✅ Coverity removed"
fi

echo "Post-check Black Duck (should show detect.sh or Black Duck Scan):"
if grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}"; then
  echo "✅ Black Duck present"
else
  echo "❌ Black Duck NOT found"
  exit 1
fi
cat "${PIPELINE_FILE}"
git config user.email "pipeline-bot@example.com"
git config user.name  "pipeline-bot"

git add -A

# Commit (if nothing staged, don't fail)
git commit -m "$COMMIT_MESSAGE" || true

# Push using HTTP header auth (avoid putting token in the URL / printing it)
# Azure DevOps guidance: avoid exposing secrets in logs/command line; use secret vars/env. [3](https://www.geeksforgeeks.org/python/how-to-define-and-call-a-function-in-python/)
# GitHub requires token-based auth for HTTPS pushes. [4](https://thebottleneckdev.com/blog/processing-yaml-files)
AUTH_B64="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')"

# Disable xtrace during push to reduce accidental leakage
set +x
git -c http.extraheader="AUTHORIZATION: basic ${AUTH_B64}" push origin "HEAD:${TARGET_BRANCH}"
set -x

echo "Push completed to branch: ${TARGET_BRANCH}"
