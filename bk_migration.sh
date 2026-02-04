#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
DRY_RUN="${DRY_RUN:-false}"
YQ_BIN="${YQ_BIN:-yq}"

# Which task indicates "Polaris task" (we replace any stage containing this task)
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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing command: $1" >&2; exit 1; }
}
need_cmd "$YQ_BIN"
need_cmd find

# Replacement stage content
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
# 1) If .stages exists: remove all stages containing Polaris task and insert replacement stage at first match index
# 2) Else if .steps exists: convert to stages pipeline:
#    - split steps into LegacyPre (before first Polaris) + LegacyPost (after first Polaris)
#    - remove Polaris steps from both
#    - insert replacement stage between them
YQ_PROGRAM="$(cat <<'YQ'
def task_matches:
  (.task? // "") | test(strenv(POLARIS_TASK_REGEX));

def stage_has_polaris:
  any(
    (.. | select(tag == "!!map") | .task? // empty)
    ;
    test(strenv(POLARIS_TASK_REGEX))
  );

def remove_polaris_steps:
  map(select((.task? // "" | test(strenv(POLARIS_TASK_REGEX))) | not));

def mk_legacy_stage($name; $display; $job; $steps):
  {
    "stage": $name,
    "displayName": $display,
    "jobs": [
      {
        "job": $job,
        "displayName": $display,
        "steps": $steps
      }
    ]
  };

if (.stages? // null) != null then
  # ---- Case 1: stages-based pipeline (your original behavior) ----
  (.stages // []) as $st
  | ($st | to_entries | map(select(.value | stage_has_polaris))) as $matches
  | if ($matches | length) == 0 then
      .
    else
      ($matches[0].key) as $idx
      | .stages = (
          $st
          | to_entries
          | map(select((.value | stage_has_polaris) | not))
          | map(.value)
        )
      | .stages = (.stages[:$idx] + load(strenv(REPL_STAGE_FILE)) + .stages[$idx:])
    end

elif (.steps? // null) != null then
  # ---- Case 2: steps-only pipeline -> convert to stages, preserve root keys ----
  (.steps // []) as $steps
  | ($steps | to_entries | map(select(.value | task_matches))) as $matches
  | if ($matches | length) == 0 then
      .
    else
      ($matches[0].key) as $first_idx
      | ($steps[:$first_idx] | remove_polaris_steps) as $pre
      | ($steps[($first_idx + 1):] | remove_polaris_steps) as $post

      # Remove .steps from root and add .stages (preserving all other root keys like trigger/pool/variables/resources/etc.)
      | del(.steps)
      | .stages = (
          (if ($pre | length) > 0
           then [ mk_legacy_stage("LegacyPre";  "Legacy steps (pre)";  "legacy_pre";  $pre) ]
           else []
           end)
          + load(strenv(REPL_STAGE_FILE))
          + (if ($post | length) > 0
             then [ mk_legacy_stage("LegacyPost"; "Legacy steps (post)"; "legacy_post"; $post) ]
             else []
             end)
        )
    end

else
  .
end
YQ
)"

echo "Scanning: $ROOT_DIR"
echo "DRY_RUN=$DRY_RUN"
echo

mapfile -t files < <(find "$ROOT_DIR" -type f \( "${PIPELINE_PATTERNS[@]}" \) 2>/dev/null)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No pipeline YAML files found."
  exit 0
fi

echo "Found ${#files[@]} candidate pipeline file(s)."
echo

updated=0
skipped=0

for f in "${files[@]}"; do
  # YAML-aware check: does this file contain SynopsysPolaris task anywhere?
  if ! POLARIS_TASK_REGEX="$POLARIS_TASK_REGEX" "$YQ_BIN" e -e \
      'any( (.. | select(tag=="!!map") | .task? // empty) | test(strenv(POLARIS_TASK_REGEX)) )' \
      "$f" >/dev/null 2>&1; then
    ((++skipped)) || true
    continue
  fi

  echo "----"
  echo "Processing: $f"

  if [[ "$DRY_RUN" == "true" ]]; then
    POLARIS_TASK_REGEX="$POLARIS_TASK_REGEX" REPL_STAGE_FILE="$STAGE_TMP" \
      "$YQ_BIN" e "$YQ_PROGRAM" "$f" >/dev/null
    echo "DRY RUN: would update $f"
    ((++updated)) || true
    continue
  fi

  cp -p "$f" "$f.bak"

  POLARIS_TASK_REGEX="$POLARIS_TASK_REGEX" REPL_STAGE_FILE="$STAGE_TMP" \
    "$YQ_BIN" e -i "$YQ_PROGRAM" "$f"

  echo "Updated. Backup saved: $f.bak"
  ((++updated)) || true
done

echo
echo "Done."
echo "Updated: $updated"
echo "Skipped: $skipped"
