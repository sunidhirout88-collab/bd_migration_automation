#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/sunidhirout88-collab/blackduck_migration_test.git"
BRANCH="blackduck_cli"
WORKDIR="target"
PIPELINE_FILE="azure-pipelines.yml"

echo "Cloning: ${REPO_URL}"
echo "Branch:  ${BRANCH}"

rm -rf "${WORKDIR}"
git clone --branch "${BRANCH}" "${REPO_URL}" "${WORKDIR}"
cd "${WORKDIR}"

# Ensure Python is available (hosted ubuntu agents typically have python3)
python3 --version

# Install dependency for YAML parsing
python3 -m pip install --user --upgrade pip
python3 -m pip install --user pyyaml

# Write the converter script to a file (IMPORTANT)
cat > convert_polaris_to_blackduck_sca.py <<'PY'
import argparse
import copy
import sys
from typing import Any, Dict

import yaml

SYNOPSYS_TASK_NAMES = {"SynopsysPolaris@1", "SynopsysPolaris@0", "SynopsysPolaris"}
BLACKDUCK_TASK = "BlackDuckSecurityScan@2"

# From Black Duck docs: ADO example uses BlackDuckSecurityScan@2 with BLACKDUCKSCA_URL and BLACKDUCKSCA_TOKEN inputs. [1](https://github.com/synopsys-sig/polaris-ado/blob/master/docs/docs.md)
DEFAULT_BLACKDUCKSCA_INPUTS = {
    "BLACKDUCKSCA_URL": "$(BLACKDUCK_URL)",
    "BLACKDUCKSCA_TOKEN": "$(BLACKDUCK_TOKEN)",
}

# Docs: Detect-specific options can be passed through Detect environment variables, e.g., project name. [1](https://github.com/synopsys-sig/polaris-ado/blob/master/docs/docs.md)[2](https://sig-synopsys.my.site.com/community/s/article/Polaris-Azure-DevOps-Pipeline-Integration)
DEFAULT_ENV = {
    "DETECT_PROJECT_NAME": "$(Build.Repository.Name)",
}

def is_synopsys_polaris_step(step: Any) -> bool:
    return isinstance(step, dict) and step.get("task") in SYNOPSYS_TASK_NAMES

def convert_step(step: Dict[str, Any]) -> Dict[str, Any]:
    new_step: Dict[str, Any] = {}

    for k in ("displayName", "condition", "continueOnError", "enabled", "timeoutInMinutes"):
        if k in step:
            new_step[k] = step[k]

    if "displayName" not in new_step:
        new_step["displayName"] = "Black Duck SCA Scan"

    new_step["task"] = BLACKDUCK_TASK
    new_step["inputs"] = copy.deepcopy(DEFAULT_BLACKDUCKSCA_INPUTS)
    new_step["env"] = copy.deepcopy(DEFAULT_ENV)

    old_inputs = step.get("inputs", {}) or {}
    if "polarisService" in old_inputs:
        new_step["env"]["_MIGRATED_FROM_POLARIS_SERVICE_CONNECTION"] = str(old_inputs["polarisService"])

    return new_step

def walk_and_convert(node: Any) -> Any:
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == "steps" and isinstance(v, list):
                new_steps = []
                for step in v:
                    if is_synopsys_polaris_step(step):
                        new_steps.append(convert_step(step))
                    else:
                        new_steps.append(walk_and_convert(step))
                out[k] = new_steps
            else:
                out[k] = walk_and_convert(v)
        return out

    if isinstance(node, list):
        return [walk_and_convert(x) for x in node]

    return node

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", help="Path to azure-pipelines.yml")
    ap.add_argument("--in-place", action="store_true", help="Overwrite input file")
    ap.add_argument("--out", help="Output file path")
    args = ap.parse_args()

    with open(args.file, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    converted = walk_and_convert(data)

    if args.in_place:
        out_path = args.file
    else:
        out_path = args.out or (args.file.replace(".yml", ".blackducksca.yml").replace(".yaml", ".blackducksca.yaml"))

    with open(out_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(converted, f, sort_keys=False)

    print(f"Converted pipeline saved to: {out_path}")

if __name__ == "__main__":
    main()
PY

# Run conversion
if [[ ! -f "${PIPELINE_FILE}" ]]; then
  echo "ERROR: ${PIPELINE_FILE} not found in repo root."
  exit 1
fi

python3 convert_polaris_to_blackduck_sca.py "${PIPELINE_FILE}" --in-place

# Commit & push if anything changed
if git diff --quiet; then
  echo "No changes detected. Nothing to commit."
  exit 0
fi

git status
git add "${PIPELINE_FILE}"
git commit -m "Migrate from SynopsysPolaris task to Black Duck SCA (BlackDuckSecurityScan@2)"
git push origin "${BRANCH}"
echo "✅ Migration complete and pushed."
