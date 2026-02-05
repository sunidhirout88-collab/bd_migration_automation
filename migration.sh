#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# migration.sh
# - Expects the target repo to already be cloned (pipeline does the clone)
# - Converts SynopsysPolaris@1 steps to BlackDuckSecurityScan@2 (Black Duck SCA)
# - Commits & pushes back to the target branch using a GitHub classic PAT
#
# Usage:
#   ./migration.sh /path/to/cloned/target/repo
#
# Required env vars (provided by your Azure Pipeline):
#   TARGET_BRANCH   -> branch name to push back to (e.g., "blackduck_cli")
#   GITHUB_TOKEN    -> classic PAT (secret). Alternatively can set GITHUB_PAT.
#
# Notes:
# - BlackDuckSecurityScan ADO with Black Duck SCA uses inputs BLACKDUCKSCA_URL
#   and BLACKDUCKSCA_TOKEN; Detect options can be passed as env vars like
#   DETECT_PROJECT_NAME. [1](https://sig-synopsys.my.site.com/community/s/article/Polaris-Configuration-for-Azure-DevOps)
# - GitHub allows PAT usage in place of a password for command-line git auth. [2](https://github.com/synopsys-sig/polaris-ado/blob/master/docs/docs.md)
# ------------------------------------------------------------------------------

TARGET_DIR="${1:-}"
if [[ -z "${TARGET_DIR}" ]]; then
  echo "ERROR: Missing target repo path."
  echo "Usage: $0 /path/to/cloned/target/repo"
  exit 1
fi

if [[ ! -d "${TARGET_DIR}/.git" ]]; then
  echo "ERROR: '${TARGET_DIR}' is not a git repository ('.git' not found)."
  exit 1
fi

: "${TARGET_BRANCH:?TARGET_BRANCH is not set}"

# Accept either env var name for the PAT
GITHUB_PAT="${GITHUB_PAT:-${GITHUB_TOKEN:-}}"
: "${GITHUB_PAT:?GITHUB_PAT (or GITHUB_TOKEN) is not set}"

cd "${TARGET_DIR}"

# Configure git identity locally for CI commit
git config user.name  "azure-pipelines-bot"
git config user.email "azure-pipelines-bot@users.noreply.github.com"

# Locate azure-pipelines YAML file (root or nested)
PIPELINE_FILE="$(find . -maxdepth 4 -type f \( -name "azure-pipelines.yml" -o -name "azure-pipelines.yaml" \) | head -n 1 || true)"
if [[ -z "${PIPELINE_FILE}" ]]; then
  echo "ERROR: Could not find azure-pipelines.yml or azure-pipelines.yaml in target repo."
  echo "YAML files found (first 200):"
  find . -maxdepth 6 -type f \( -name "*.yml" -o -name "*.yaml" \) | head -n 200
  exit 1
fi
PIPELINE_FILE="${PIPELINE_FILE#./}"
echo "Using pipeline file: ${PIPELINE_FILE}"

# Ensure python + pyyaml are available
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found on agent."
  exit 1
fi

python3 -m pip install --user --quiet --upgrade pip >/dev/null 2>&1 || true
python3 -m pip install --user --quiet pyyaml >/dev/null 2>&1 || true

# Create converter script in temp file (keeps repo clean)
SCRIPT_PATH="$(mktemp)"
trap 'rm -f "${SCRIPT_PATH:-}"' EXIT

cat > "${SCRIPT_PATH}" <<'PY'
import argparse
import copy
from typing import Any, Dict
import yaml

SYNOPSYS_TASK_NAMES = {"SynopsysPolaris@1", "SynopsysPolaris@0", "SynopsysPolaris"}
BLACKDUCK_TASK = "BlackDuckSecurityScan@2"

# Black Duck Security Scan ADO (Black Duck SCA) example uses BLACKDUCKSCA_URL and BLACKDUCKSCA_TOKEN. [1](https://sig-synopsys.my.site.com/community/s/article/Polaris-Configuration-for-Azure-DevOps)
DEFAULT_INPUTS = {
    "BLACKDUCKSCA_URL": "$(BLACKDUCK_URL)",
    "BLACKDUCKSCA_TOKEN": "$(BLACKDUCK_TOKEN)",
}

# Detect configuration can be passed through Detect environment variables (example: DETECT_PROJECT_NAME). [1](https://sig-synopsys.my.site.com/community/s/article/Polaris-Configuration-for-Azure-DevOps)
DEFAULT_ENV = {
    "DETECT_PROJECT_NAME": "$(Build.Repository.Name)",
}

def is_polaris_step(step: Any) -> bool:
    return isinstance(step, dict) and step.get("task") in SYNOPSYS_TASK_NAMES

def convert_step(step: Dict[str, Any]) -> Dict[str, Any]:
    new_step: Dict[str, Any] = {}

    # Preserve common step controls if present
    for k in ("displayName", "condition", "continueOnError", "enabled", "timeoutInMinutes"):
        if k in step:
            new_step[k] = step[k]

    if "displayName" not in new_step:
        new_step["displayName"] = "Black Duck SCA Scan"

    new_step["task"] = BLACKDUCK_TASK
    new_step["inputs"] = copy.deepcopy(DEFAULT_INPUTS)
    new_step["env"] = copy.deepcopy(DEFAULT_ENV)

    return new_step

def walk(node: Any) -> Any:
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == "steps" and isinstance(v, list):
                converted_steps = []
                for s in v:
                    if is_polaris_step(s):
                        converted_steps.append(convert_step(s))
                    else:
                        converted_steps.append(walk(s))
                out[k] = converted_steps
            else:
                out[k] = walk(v)
        return out

    if isinstance(node, list):
        return [walk(x) for x in node]

    return node

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--in-place", action="store_true")
    args = ap.parse_args()

    with open(args.file, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    converted = walk(data)
    out_path = args.file if args.in_place else (args.file + ".blackducksca.yml")

    with open(out_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(converted, f, sort_keys=False)

    print(f"Converted pipeline saved to: {out_path}")

if __name__ == "__main__":
    main()
PY

# Run conversion in-place
python3 "${SCRIPT_PATH}" "${PIPELINE_FILE}" --in-place

# Nothing to commit?
if git diff --quiet; then
  echo "No changes detected. Nothing to commit."
  exit 0
fi

# Stage and commit only the pipeline YAML
git add "${PIPELINE_FILE}"
git commit -m "Migrate pipeline: Polaris -> Black Duck SCA server scan"

# Helper: base64 without wrapping (Linux/macOS)
b64_no_wrap() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

# Push using PAT securely via Authorization header (avoids storing token in remote URL)
# GitHub PAT can be used in place of a password for command-line git operations. [2](https://github.com/synopsys-sig/polaris-ado/blob/master/docs/docs.md)
set +x
AUTH_HEADER=$(printf "x-access-token:%s" "${GITHUB_PAT}" | b64_no_wrap)
set -x

git -c http.extraheader="AUTHORIZATION: basic ${AUTH_HEADER}" push origin "HEAD:${TARGET_BRANCH}"

echo "✅ Migration complete and pushed to ${TARGET_BRANCH}"
