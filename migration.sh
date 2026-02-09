#!/usr/bin/env bash
set -euo pipefail

# Resolve script location safely
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

echo "SCRIPT PATH: ${SCRIPT_PATH}"
echo "SCRIPT HASH: $(sha256sum "${SCRIPT_PATH}" | awk '{print $1}')"

# Move to folder containing azure-pipelines.yml
if [[ -f "${SCRIPT_DIR}/target/azure-pipelines.yml" ]]; then
  cd "${SCRIPT_DIR}/target"
elif [[ -f "${SCRIPT_DIR}/azure-pipelines.yml" ]]; then
  cd "${SCRIPT_DIR}"
else
  echo "ERROR: Cannot locate azure-pipelines.yml in ${SCRIPT_DIR} or ${SCRIPT_DIR}/target"
  exit 1
fi

PIPELINE_FILE="azure-pipelines.yml"

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq (Mike Farah, v4+) is required."
  exit 1
fi

echo "Using yq: $(yq --version)"
echo "PWD: $(pwd)"
echo "Editing: ${PIPELINE_FILE}"

# Backup
cp -p "${PIPELINE_FILE}" "${PIPELINE_FILE}.bak"

# Keep only first YAML document (protect against old eval-all multi-doc output) [2](https://github.com/mikefarah/yq/issues/1642)[3](https://unix.stackexchange.com/questions/561460/how-to-print-path-and-key-values-of-json-file)
yq e -i 'select(di == 0)' "${PIPELINE_FILE}"

# --- Black Duck variables (map) ---
BD_VARS="$(mktemp)"
cat > "${BD_VARS}" <<'YAML'
BLACKDUCK_URL: 'https://blackduck.mycompany.com'
BD_PROJECT: 'my-app'
BD_VERSION: '$(Build.SourceBranchName)'
DETECT_VERSION: 'latest'
YAML

# --- Black Duck steps (sequence) ---
BD_STEPS="$(mktemp)"
cat > "${BD_STEPS}" <<'YAML'
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
    BLACKDUCK_API_TOKEN: $(BLACKDUCK_API_TOKEN)

- task: PublishBuildArtifacts@1
  displayName: "Publish Black Duck Reports"
  inputs:
    PathtoPublish: "$(Build.SourcesDirectory)/blackduck"
    ArtifactName: "blackduck-reports"
  condition: succeededOrFailed()
YAML

export BD_VARS BD_STEPS

# --- Debug BEFORE ---
echo "Coverity bash-step count BEFORE (cov- in .bash):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)cov-"))) | length' "${PIPELINE_FILE}" || true
echo "BlackDuck detect-step count BEFORE (detect.sh in .bash):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)detect\.sh"))) | length' "${PIPELINE_FILE}" || true

echo "Before hash:"; sha256sum "${PIPELINE_FILE}" || true

# -------------------------------------------------------------------
# 1) REMOVE COVERITY: variables + steps (single deterministic yq edit)
# -------------------------------------------------------------------
yq e -i '
  # Drop COVERITY_* variables (handles map or seq)
  (if .variables == null then .
   elif (.variables | type) == "!!map" then
     .variables |= with_entries(select((.key | test("^COVERITY_")) | not))
   elif (.variables | type) == "!!seq" then
     .variables |= map(select((.name // "" | test("^COVERITY_")) | not))
   else .
   end)
  |
  # Drop Coverity steps:
  # - any bash/script/pwsh/powershell containing cov-
  # - any displayName/task containing coverity
  # - any publish step with coverity artifact/path
  (.steps |= map(
    select(
      (
        ((.bash // "") + " " + (.script // "") + " " + (.pwsh // "") + " " + (.powershell // "")) | test("(?i)cov-")
      )
      or (
        ((.displayName // "") + " " + (.task // "")) | test("(?i)coverity")
      )
      or (
        ((.inputs.artifactName // "") + " " + (.inputs.ArtifactName // "")) | test("(?i)coverity")
      )
      or (
        ((.inputs.pathToPublish // "") + " " + (.inputs.PathtoPublish // "")) | test("(?i)coverity|\\$\\(coverity_")
      )
      | not
    )
  ))
' "${PIPELINE_FILE}"

# -------------------------------------------------------------------
# 2) MERGE BD VARS (safe map merge; your variables are a map)
# -------------------------------------------------------------------
yq e -i '
  .variables = ((.variables // {}) * load(strenv(BD_VARS)))
' "${PIPELINE_FILE}"

# -------------------------------------------------------------------
# 3) INJECT BD STEPS if detect.sh not present
#    Insert right after first step (checkout) if steps exist.
# -------------------------------------------------------------------
yq e -i '
  if (.steps // [] | any((.bash // "") | test("(?i)detect\\.sh"))) then
    .
  else
    .steps = (
      if (.steps | length) > 0 then
        .steps[0:1] + load(strenv(BD_STEPS)) + .steps[1:]
      else
        load(strenv(BD_STEPS))
      end
    )
  end
' "${PIPELINE_FILE}"

echo "After hash:"; sha256sum "${PIPELINE_FILE}" || true

# --- Debug AFTER ---
echo "Coverity bash-step count AFTER (cov- in .bash):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)cov-"))) | length' "${PIPELINE_FILE}" || true
echo "BlackDuck detect-step count AFTER (detect.sh in .bash):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)detect\.sh"))) | length' "${PIPELINE_FILE}" || true

# Cleanup temp files
rm -f "${BD_VARS}" "${BD_STEPS}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check Coverity (should be EMPTY):"
if grep -nE '^[^#]*\bcov-' -n "${PIPELINE_FILE}"; then
  echo "❌ Coverity still present"
else
  echo "✅ Coverity removed"
fi

echo "Post-check Black Duck (should show detect.sh or Black Duck Scan):"
if grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}"; then
  echo "✅ Black Duck present"
else
  echo "❌ Black Duck NOT found"
fi
