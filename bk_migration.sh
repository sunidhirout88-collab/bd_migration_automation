#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
DRY_RUN="${DRY_RUN:-false}"
YQ_BIN="${YQ_BIN:-yq}"

TARGET_STAGE="SynopsysPolaris"

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
need_cmd grep

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

# ✅ FIX: use cat heredoc into variable instead of read -d ''
YQ_PROGRAM="$(cat <<'YQ'
def is_target_stage(s): (s.stage // "") == strenv(TARGET_STAGE);

if (.stages? // null) == null then
  .
else
  (.stages // []) as $st
  | ($st | to_entries | map(select(.value | is_target_stage(.)))) as $matches
  | if ($matches | length) == 0 then
      .
    else
      ($matches[0].key) as $idx
      | .stages = ($st | to_entries | map(select((.value | is_target_stage(.)) | not)) | map(.value))
      | .stages = (.stages[:$idx] + load(strenv(REPL_STAGE_FILE)) + .stages[$idx:])
    end
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
  if ! grep -qE '^\s*-\s*stage:\s*SynopsysPolaris\s*$' "$f"; then
    ((skipped++)) || true
    continue
  fi

  echo "----"
  echo "Processing: $f"

  if [[ "$DRY_RUN" == "true" ]]; then
    TARGET_STAGE="$TARGET_STAGE" REPL_STAGE_FILE="$STAGE_TMP" \
      "$YQ_BIN" e "$YQ_PROGRAM" "$f" >/dev/null
    echo "DRY RUN: would update $f"
    ((updated++)) || true
    continue
  fi

  cp -p "$f" "$f.bak"

  TARGET_STAGE="$TARGET_STAGE" REPL_STAGE_FILE="$STAGE_TMP" \
    "$YQ_BIN" e -i "$YQ_PROGRAM" "$f"

  echo "Updated. Backup saved: $f.bak"
  ((updated++)) || true
done

echo
echo "Done."
echo "Updated: $updated"
echo "Skipped: $skipped"
