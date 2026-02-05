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
DEFAULT_ENV = {"DETECT_PROJECT_NAME": "$(Build.Repository.Name)"}

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
    ap.add_argument("file")
    ap.add_argument("--in-place", action="store_true")
    args = ap.parse_args()

    with open(args.file, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    converted = walk_and_convert(data)
    out_path = args.file if args.in_place else args.file + ".blackducksca.yml"

    with open(out_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(converted, f, sort_keys=False)

    print(f"Converted pipeline saved to: {out_path}")

if __name__ == "__main__":
    main()
PY

python3 "${SCRIPT_PATH}" azure-pipelines.yml --in-place
rm -f "${SCRIPT_PATH}"
