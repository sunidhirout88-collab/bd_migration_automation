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

# ✅ Git identity for commits on CI
git config user.name  "azure-pipelines-bot"
git config user.email "azure-pipelines-bot@users.noreply.github.com"

python3 --version
python3 -m pip install --user --upgrade pip
python3 -m pip install --user pyyaml

# ✅ Create python converter in a temp file (avoid untracked file in repo)
SCRIPT_PATH="$(mktemp)"

cat > "${SCRIPT_PATH}" <<'PY'
import argparse
import copy
from typing import Any, Dict
import yaml

SYNOPSYS_TASK_NAMES = {"SynopsysPolaris@1", "SynopsysPolaris@0", "SynopsysPolaris"}
BLACKDUCK_TASK = "BlackDuckSecurityScan@2"

DEFAULT_BLACKDUCKSCA_INPUTS = {
    "BLACKDUCKSCA_URL": "$(BLACKDUCK_URL)",
    "BLACKDUCKSCA_TOKEN": "$(BLACKDUCK_TOKEN)",
}

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
