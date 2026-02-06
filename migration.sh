#!/usr/bin/env bash
set -euo pipefail

# Usage: ./replace_coverity_stage.sh azure-pipelines.yml
PIPELINE_FILE="azure-pipelines.yml"

ls -la target
find target -maxdepth 2 -name "azure-pipelines.y*ml" -print

if [[ -z "${PIPELINE_FILE}" || ! -f "${PIPELINE_FILE}" ]]; then
  echo "Usage: $0 <pipeline-yaml-file>"
  echo "Error: file not found: ${PIPELINE_FILE}"
  exit 1
fi

# ---- Check yq availability (Mike Farah yq v4) ----
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: 'yq' (Mike Farah, v4+) is required but not installed."
  echo "Install examples:"
  echo "  macOS:  brew install yq"
  echo "  Linux:  https://github.com/mikefarah/yq/#install"
  exit 1
fi

# ---- Create the replacement stage YAML in a temp file ----
TMP_STAGE="$(mktemp)"
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
yq -i '
  .stages = (.stages // [])
' "${PIPELINE_FILE}"

# ---- Find index of stage named "coverity" (case-insensitive), matching either .stage or .name ----
COV_IDX="$(yq e '
  (.stages // [])
  | to_entries
  | map(select((.value.stage // .value.name // "") | ascii_downcase == "coverity"))
  | .[0].key
' "${PIPELINE_FILE}")"

# yq prints "null" if not found
if [[ "${COV_IDX}" == "null" || -z "${COV_IDX}" ]]; then
  echo "No 'coverity' stage found. Appending 'blackduckcoverity' stage."
  # Append the new stage
  yq -i '
    .stages += [load(strenv(TMP_STAGE))]
  ' "${PIPELINE_FILE}" TMP_STAGE="${TMP_STAGE}"
else
  echo "Found 'coverity' stage at index ${COV_IDX}. Replacing with 'blackduckcoverity'."

  # Delete coverity at that index
  yq -i "del(.stages[${COV_IDX}])" "${PIPELINE_FILE}"

  # Insert new stage at same index
  # Use env var for index; yq slicing requires numeric index
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

rm -f "${TMP_STAGE}"
echo "Done. Updated: ${PIPELINE_FILE}"
