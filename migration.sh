#!/usr/bin/env python3
"""
Convert Azure DevOps YAML pipeline steps from SynopsysPolaris@1 task
to BlackDuckSecurityScan@2 configured for Black Duck SCA (server/Hub).

Usage:
  python convert_polaris_to_blackduck_sca.py azure-pipelines.yml
  python convert_polaris_to_blackduck_sca.py azure-pipelines.yml --in-place
  python convert_polaris_to_blackduck_sca.py azure-pipelines.yml --out new.yml
"""

import argparse
import copy
import sys
from typing import Any, Dict

try:
    import yaml
except ImportError:
    print("Missing dependency: pyyaml. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(2)

# Task names we will replace
SYNOPSYS_TASK_NAMES = {"SynopsysPolaris@1", "SynopsysPolaris@0", "SynopsysPolaris"}

# Task name we will insert (from Black Duck Security Scan ADO docs)
BLACKDUCK_TASK = "BlackDuckSecurityScan@2"

# Default inputs for Black Duck SCA mode (from official example)
# BLACKDUCKSCA_URL and BLACKDUCKSCA_TOKEN are shown in the docs. [1](https://documentation.blackduck.com/bundle/bridge/page/documentation/c_azure-with-blackduck.html)
DEFAULT_BLACKDUCKSCA_INPUTS = {
    "BLACKDUCKSCA_URL": "$(BLACKDUCK_URL)",
    "BLACKDUCKSCA_TOKEN": "$(BLACKDUCK_TOKEN)",
    # Optional, commonly enabled:
    # "BLACKDUCKSCA_PRCOMMENT_ENABLED": True,  # requires AZURE_TOKEN
    # "BLACKDUCKSCA_FIXPR_ENABLED": True,      # requires AZURE_TOKEN
    # "BLACKDUCKSCA_REPORTS_SARIF_CREATE": True,
    # "AZURE_TOKEN": "$(System.AccessToken)",
}

# Default env: Detect settings can be passed through Detect env vars. [1](https://documentation.blackduck.com/bundle/bridge/page/documentation/c_azure-with-blackduck.html)[4](https://documentation.blackduck.com/bundle/bridge/page/documentation/c_using-bridge-with-black-duck.html)
DEFAULT_ENV = {
    "DETECT_PROJECT_NAME": "$(Build.Repository.Name)",
}

def is_synopsys_polaris_step(step: Any) -> bool:
    return isinstance(step, dict) and step.get("task") in SYNOPSYS_TASK_NAMES

def convert_step(step: Dict[str, Any]) -> Dict[str, Any]:
    new_step: Dict[str, Any] = {}

    # Preserve some common step keys if present
    for k in ("displayName", "condition", "continueOnError", "enabled", "timeoutInMinutes"):
        if k in step:
            new_step[k] = step[k]

    # If no displayName, set a clear one
    if "displayName" not in new_step:
        new_step["displayName"] = "Black Duck SCA Scan"

    new_step["task"] = BLACKDUCK_TASK
    new_step["inputs"] = copy.deepcopy(DEFAULT_BLACKDUCKSCA_INPUTS)

    # Add Detect env defaults (can be expanded by you later)
    new_step["env"] = copy.deepcopy(DEFAULT_ENV)

    # Best-effort hints: old task used service connection; new task uses vars.
    old_inputs = step.get("inputs", {}) or {}
    if "polarisService" in old_inputs:
        new_step["env"]["_MIGRATED_FROM_POLARIS_SERVICE_CONNECTION"] = str(old_inputs["polarisService"])

    return new_step

def walk_and_convert(node: Any) -> Any:
    """
    Recursively walk YAML object and convert steps.
    Typical ADO shapes:
      - steps: [...]
      - jobs: [{ steps: [...] }]
      - stages: [{ jobs: [...] }]
    """
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
    ap.add_argument("file", help="Path to azure-pipelines.yml (or any pipeline YAML)")
    ap.add_argument("--out", help="Output file path (default: <input>.blackducksca.yml)")
    ap.add_argument("--in-place", action="store_true", help="Overwrite input file")
    args = ap.parse_args()

    with open(args.file, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    converted = walk_and_convert(data)

    if args.in_place:
        out_path = args.file
    else:
        if args.out:
            out_path = args.out
        else:
            if args.file.endswith(".yaml"):
                out_path = args.file[:-5] + ".blackducksca.yaml"
            elif args.file.endswith(".yml"):
                out_path = args.file[:-4] + ".blackducksca.yml"
            else:
                out_path = args.file + ".blackducksca.yml"

    with open(out_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(converted, f, sort_keys=False)

    print(f"✅ Converted pipeline saved to: {out_path}")
    print("\nNext steps required (manual):")
    print("1) Install Black Duck Security Scan extension in your Azure DevOps org.")
    print("   https://marketplace.visualstudio.com/items?itemName=blackduck.blackduck-security-scan")
    print("2) Create pipeline variables or a Variable Group containing:")
    print("   - BLACKDUCK_URL (example: https://your-blackduck-server)")
    print("   - BLACKDUCK_TOKEN (secret)")
    print("3) If you enable PR comments or Fix PRs, you must also set:")
    print("   - AZURE_TOKEN: $(System.AccessToken) and ensure permissions are granted.")

if __name__ == "__main__":
    main()
