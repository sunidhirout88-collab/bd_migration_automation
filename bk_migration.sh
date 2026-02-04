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

# Write the yq program to a file (more reliable than passing multiline via CLI)
YQ_PROG_FILE="$(mktemp)"
cat > "$YQ_PROG_FILE" <<'YQ'
def task_matches:
  ((.task? // "") | test(strenv(POLARIS_TASK_REGEX)));

def stage_has_polaris:
  (
    [ .. | select(tag == "!!map") | .task? | select(.) | select(test(strenv(POLARIS_TASK_REGEX))) ]
    | length
  ) > 0;

def remove_polaris_steps:
  map(select(((.task? // "") | test(strenv(POLARIS_TASK_REGEX))) | not));

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
  (.steps // []) as $steps
  | ($steps | to_entries | map(select(.value | task_matches))) as $matches
  | if ($matches | length) == 0 then
      .
    else
      ($matches[0].key) as $first_idx
      | ($steps[:$first_idx] | remove_polaris_steps) as $pre
      | ($steps[($first_idx + 1):] | remove_polaris_steps) as $post
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

cleanup() { rm -f "$STAGE_TMP" "$YQ_PROG_FILE"; }
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

  # Robust detection: array+length
  if ! POLARIS_TASK_REGEX="$POLARIS_TASK_REGEX" "$YQ_BIN" e -e \
      '([.. | select(tag=="!!map") | .task? | select(.) | select(test(strenv(POLARIS_TASK_REGEX)))] | length) > 0' \
      "$f" >/dev/null 2>&1; then
    echo "Detection result: NO MATCH -> skipping"
    ((++skipped)) || true
    continue
  fi

  echo "Detection result: MATCH -> processing"
  echo "Processing: $f"

  if [[ "$DRY_RUN" == "true" ]]; then
    POLARIS_TASK_REGEX="$POLARIS_TASK_REGEX" REPL_STAGE_FILE="$STAGE_TMP" \
      "$YQ_BIN" e --from-file "$YQ_PROG_FILE" "$f" >/dev/null
    echo "DRY RUN: would update $f"
    ((++updated)) || true
    continue
  fi

  cp -p "$f" "$f.bak"

  POLARIS_TASK_REGEX="$POLARIS_TASK_REGEX" REPL_STAGE_FILE="$STAGE_TMP" \
    "$YQ_BIN" e -i --from-file "$YQ_PROG_FILE" "$f"

  echo "Updated. Backup saved: $f.bak"
  ((++updated)) || true
done

echo
echo "Done."
echo "Updated: $updated"
echo "Skipped: $skipped"
