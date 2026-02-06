#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# migration.sh
# Replaces a stage named "coverity" (case-insensitive) with "blackduckcoverity"
# in an Azure DevOps pipeline YAML.
#
# Usage:
#   ./migration.sh [path-to-pipeline-yaml]
#
# Examples:
#   ./migration.sh target/azure-pipelines.yml
#   ./migration.sh                     # auto-detects in ./target or current dir
# ------------------------------------------------------------------------------

log()  { echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---- Resolve PIPELINE_FILE ----
PIPELINE_FILE="${1:-}"

# Common locations to search when not provided
AUTO_CANDIDATES=(
  "target/azure-pipelines.yml"
  "target/azure-pipelines.yaml"
  "azure-pipelines.yml"
  "azure-pipelines.yaml"
)

if [[ -z "${PIPELINE_FILE}" ]]; then
  for f in "${AUTO_CANDIDATES[@]}"; do
    if [[ -f "$f" ]]; then
      PIPELINE_FILE="$f"
      break
    fi
  done
fi

if [[ -z "${PIPELINE_FILE}" || ! -f "${PIPELINE_FILE}" ]]; then
  echo "Usage: $0 <pipeline-yaml-file>"
  echo "Error: file not found: ${PIPELINE_FILE:-"(not provided)"}"
  echo "Tried:"
  printf '  - %s\n' "${AUTO_CANDIDATES[@]}"
  echo "Current dir: $(pwd)"
  exit 1
fi

log "Working directory: $(pwd)"
log "Pipeline file: ${PIPELINE_FILE}"

# ---- Check yq availability (Mike Farah yq v4) ----
if ! command -v yq >/dev/null 2>&1; then
  die "'yq' (Mike Farah, v4+) is required but not installed."
fi

# Print yq version for diagnostics
YQ_VER="$(yq --version 2>/dev/null || yq -V 2>/dev/null || true)"
log "Using yq: ${YQ_VER:-unknown}"

# ---- Create the replacement stage YAML in a temp file ----
TMP_STAGE="$(mktemp)"
cleanup() { rm -f "${TMP_STAGE}"; }
trap cleanup EXIT

cat > "${TMP_STAGE}" <<'YAML'
stage: blackduckcoverity
displayName: "Black Duck Scan (Synopsys Detect)"
variables:
  BLACKDUCK_URL: 'https://blackduck.mycompany.com'
  BD_PROJECT: 'my-app'
  BD_VERSION: '$(Build.SourceBranchName)'
  DETECT_VERSION: 'latest'   # or pin e.g. 9.10.0

jobs:
  - job: blackduck_scan
    displayName: "Black Duck Scan"
    steps:
      - checkout: self
        fetchDepth: 0

      # (Optional) Use Java if Detect needs it (depending on Detect packaging/version)
      - task: JavaToolInstaller@0
        displayName: "Use Java 11"
        inputs:
          versionSpec: '11'
          jdkArchitectureOption: 'x64'
          jdkSourceOption: 'PreInstalled'

      - bash: |
          set -euo pipefail

          echo "Downloading Synopsys Detect..."
          curl -fsSL -o detect.sh https://detect.synopsys.com/detect.sh
          chmod +x detect.sh

          echo "Running Black Duck scan via Synopsys Detect..."
          ./detect.sh \
            --blackduck.url="$(BLACKDUCK_URL)" \
            --blackduck.api.token="$(BLACKDUCK_API_TOKEN)" \
            --detect.project.name="$(BD_PROJECT)" \
            --detect.project.version.name="$(BD_VERSION)" \
            --detect.source.path="$(Build.SourcesDirectory)" \
            --detect.tools=DETECTOR,SIGNATURE_SCAN \
            --detect.detector.search.depth=6 \
            --detect.wait.for.results=true \
            --detect.notices.report=true \
            --detect.risk.report.pdf=true \
            --logging.level.com.synopsys.integration=INFO \
            --detect.cleanup=true
        displayName: "Black Duck Scan (Synopsys Detect)"
        env:
          # Store BLACKDUCK_API_TOKEN as a secret variable in pipeline/library
          BLACKDUCK_API_TOKEN: $(BLACKDUCK_API_TOKEN)

      # Publish generated reports (paths may vary slightly by Detect version/config)
      - task: PublishBuildArtifacts@1
        displayName: "Publish Black Duck Reports"
        inputs:
          PathtoPublish: "$(Build.SourcesDirectory)/blackduck"
          ArtifactName: "blackduck-reports"
        condition: succeededOrFailed()
YAML

# ---- Ensure .stages exists ----
# This guarantees .stages is an array, even if missing.
yq -i '
  .stages = (.stages // [])
' "${PIPELINE_FILE}"

# ---- Find index of stage named "coverity" (case-insensitive) ----
# NOTE: We avoid ascii_downcase because it requires newer yq versions (v4.21.1+). [1](https://github.com/mikefarah/yq/issues/1111)
# Instead we use case-insensitive regex: test("(?i)^coverity$")
COV_IDX="$(yq e '
  (.stages // [])
  | to_entries
  | map(
      select(
        ((.value.stage // .value.name // "") | test("(?i)^coverity$"))
      )
    )
  | .[0].key
' "${PIPELINE_FILE}")"

log "Coverity stage index (if any): ${COV_IDX}"

# yq prints "null" if not found
if [[ "${COV_IDX}" == "null" || -z "${COV_IDX}" ]]; then
  log "No 'coverity' stage found. Appending 'blackduckcoverity' stage."

  # Append the new stage
  yq -i '
    .stages += [load(strenv(TMP_STAGE))]
  ' "${PIPELINE_FILE}" TMP_STAGE="${TMP_STAGE}"

else
  log "Found 'coverity' stage at index ${COV_IDX}. Replacing with 'blackduckcoverity'."

  # Delete coverity at that index
  yq -i "del(.stages[${COV_IDX}])" "${PIPELINE_FILE}"

  # Insert new stage at same index
  export COV_IDX
  export TMP_STAGE
  yq -i '
    .stages |= (
      .[:env(COV_IDX)] +
      [load(strenv(TMP_STAGE))] +
      .[env(COV_IDX):]
    )
  ' "${PIPELINE_FILE}"
fi

log "Done. Updated: ${PIPELINE_FILE}"
