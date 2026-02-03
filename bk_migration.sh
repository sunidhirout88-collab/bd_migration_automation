#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
ROOT_DIR="${1:-.}"
YQ_BIN="${YQ_BIN:-yq}"
DRY_RUN="${DRY_RUN:-false}"

# Pipeline file patterns to scan
# (add/remove patterns as needed)
PIPELINE_FIND_EXPR=(
  -name "azure-pipelines.yml" -o
  -name "azure-pipelines.yaml" -o
  -name "*pipeline*.yml" -o
  -name "*pipeline*.yaml" -o
  -path "*/.azuredevops/*.yml" -o
  -path "*/.azuredevops/*.yaml" -o
  -path "*/.pipelines/*.yml" -o
  -path "*/.pipelines/*.yaml"
)

# New stage content (your requested tasks wrapped as a stage)
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

# -----------------------------
# Helpers
# -----------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  }
}

need_cmd "$YQ_BIN"
need_cmd find

echo "Scanning repo: $ROOT_DIR"
echo "Dry run: $DRY_RUN"
echo

# Find candidate pipeline YAML files
mapfile -t files < <(
  find "$ROOT_DIR" -type f \( "${PIPELINE_FIND_EXPR[@]}" \) 2>/dev/null
)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No pipeline YAML files found with configured patterns."
  exit 0
fi

echo "Found ${#files[@]} candidate pipeline file(s)."
echo

# -----------------------------
# yq program:
# - If .stages exists and any stage has a SynopsysPolaris task => remove those stages and insert new stage at the first match index.
# - Else if root has steps and contains SynopsysPolaris task => replace only those steps with the two tasks (no stage to remove).
# -----------------------------
read -r -d '' YQ_PROGRAM <<'YQ'
def has_polaris_task:
  any(.. | select(tag == "!!map") | .task? // "" | test("^SynopsysPolaris@"));

def stage_has_polaris:
  (.. | select(tag == "!!map") | .steps? // empty | .. | .task? // "" | test("^SynopsysPolaris@")) // false;

# MAIN
if (.stages? // null) != null then
  # Work on stages
  (.stages // []) as $st
  | ($st | to_entries | map(select(.value | stage_has_polaris))) as $matches
  | if ($matches | length) > 0 then
      ($matches[0].key) as $first
      # Remove all polaris stages
      | .stages = ($st | to_entries | map(select((.value | stage_has_polaris) | not)) | map(.value))
      # Insert new stage at the first removed stage position
      | .stages = (.stages[:$first] + load(strenv(STAGE_FILE)) + .stages[$first:])
    else
      .
    end
elif (.steps? // null) != null then
  # No stages, but root-level steps exist
  if (has_polaris_task) then
    .steps = (
      [ load(strenv(STAGE_FILE))[0].jobs[0].steps[] ]
    )
  else
    .
  end
else
  .
end
YQ

# -----------------------------
# Process files
# -----------------------------
updated=0
skipped=0

for f in "${files[@]}"; do
  # Quick check (fast): contains SynopsysPolaris@ anywhere
  if ! grep -qE 'SynopsysPolaris@' "$f"; then
    ((skipped++))
    continue
  fi

  echo "----"
  echo "Processing: $f"

  if [[ "$DRY_RUN" == "true" ]]; then
    # Print what would change (best-effort)
    STAGE_FILE="$STAGE_TMP" "$YQ_BIN" e "$YQ_PROGRAM" "$f" >/dev/null
    echo "DRY_RUN=true -> Would update (contains SynopsysPolaris@)."
    ((updated++))
    continue
  fi

  # Backup
  cp -p "$f" "$f.bak"

  # Apply changes in-place
  STAGE_FILE="$STAGE_TMP" "$YQ_BIN" e -i "$YQ_PROGRAM" "$f"

  echo "Updated. Backup saved as: $f.bak"
  ((updated++))
done

echo
echo "Done."
echo "Updated: $updated"
echo "Skipped: $skipped"
``
