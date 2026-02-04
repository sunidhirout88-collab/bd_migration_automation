#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
DRY_RUN="${DRY_RUN:-false}"
YQ_BIN="${YQ_BIN:-yq}"

# Stage name to find (case-insensitive match)
TARGET_STAGE_NAME="synopsispolaris"

# Where to search for pipeline YAMLs (customize as needed)
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
need_cmd grep

# Create the replacement stage YAML (valid Azure DevOps structure)
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

# yq program:
# - If .stages exists and contains a stage with .stage == synopsispolaris (case-insensitive)
#   remove it and insert replacement stage in the same position
read -r -d '' YQ_PROGRAM <<'YQ'
def stage_name(e):
  (e.stage // "") | tostring | ascii_downcase;

(.stages // null) as $stages
| if $stages == null then
    .
  else
    ($stages | to_entries | map(select(stage_name(.value) == (strenv(TARGET_STAGE) | ascii_downcase)))) as $matches
    | if ($matches | length) == 0 then
        .
      else
        ($matches[0].key) as $idx
        # remove all stages named synopsispolaris (in case there are multiple)
        | .stages = (
            $stages
            | to_entries
            | map(select(stage_name(.value) != (strenv(TARGET_STAGE) | ascii_downcase)))
            | map(.value)
          )
        # insert replacement stage at original position
        | .stages = (.stages[:$idx] + load(strenv(REPL_STAGE_FILE)) + .stages[$idx:])
      end
  end
YQ

echo "Scanning: $ROOT_DIR"
echo "DRY_RUN=$DRY_RUN"
echo

mapfile -t files < <(find "$ROOT_DIR" -type f \( "${PIPELINE_PATTERNS[@]}" \) 2>/dev/null)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No pipeline YAML files found using configured patterns."
  exit 0
fi

echo "Found ${#files[@]} candidate file(s)."
echo

updated=0
skipped=0

for f in "${files[@]}"; do
  # Quick filter: only consider files that even mention 'stages:' or 'stage:'
  if ! grep -qE '(^|\s)stages:|(^|\s)-\s*stage:' "$f"; then
    ((skipped++)) || true
    continue
  fi

  # Check if stage name appears (fast pre-check, case-insensitive)
  if ! grep -qiE "^\s*-\s*stage:\s*${TARGET_STAGE_NAME}\s*$" "$f"; then
    # It may be written like: stage: SynopsysPolaris (without dash on same line due to formatting),
    # so we still allow yq to decide, but we can skip most files quickly.
    # Comment the next line if you want yq to inspect every candidate file:
    ((skipped++)) || true
    continue
  fi

  echo "----"
  echo "Processing: $f"

  if [[ "$DRY_RUN" == "true" ]]; then
    TARGET_STAGE="$TARGET_STAGE_NAME" REPL_STAGE_FILE="$STAGE_TMP" "$YQ_BIN" e "$YQ_PROGRAM" "$f" >/dev/null
    echo "DRY RUN: would update $f"
    ((updated++)) || true
    continue
  fi

  cp -p "$f" "$f.bak"

  TARGET_STAGE="$TARGET_STAGE_NAME" REPL_STAGE_FILE="$STAGE_TMP" \
    "$YQ_BIN" e -i "$YQ_PROGRAM" "$f"

  echo "Updated. Backup: $f.bak"
  ((updated++)) || true
done

echo
echo "Done."
echo "Updated: $updated"
echo "Skipped: $skipped"
