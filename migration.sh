#!/usr/bin/env bash
set -euo pipefail

# --- Resolve script path (works even after cd) ---
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

echo "SCRIPT PATH: ${SCRIPT_PATH}"
echo "SCRIPT HASH: $(sha256sum "${SCRIPT_PATH}" | awk '{print $1}')"

# --- Move to folder containing azure-pipelines.yml ---
# Repo has a cloned folder "target/" that contains the YAML
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

# --- Backup ---
cp -p "${PIPELINE_FILE}" "${PIPELINE_FILE}.bak"

# Keep only the first YAML document (avoids leftover multi-doc output from eval-all runs) [2](https://github.com/mikefarah/yq/issues/1642)[3](https://stackoverflow.com/questions/70032588/use-yq-to-substitute-string-in-a-yaml-file)
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

# --- yq program: EXACTLY matches your YAML structure ---
# NOTE: We match Coverity using the actual fields where it appears:
# - .bash contains cov-build/cov-analyze etc
# - publish steps use artifactName/pathToPublish containing coverity
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
def low(x): (x // "" | tostring | ascii_downcase);

def blob:
  (
    low(.displayName) + "\n" +
    low(.task) + "\n" +
    low(.bash) + "\n" +
    low(.script) + "\n" +
    low(.pwsh) + "\n" +
    low(.powershell) + "\n" +
    low(.inputs.pathToPublish) + "\n" +
    low(.inputs.PathtoPublish) + "\n" +
    low(.inputs.artifactName) + "\n" +
    low(.inputs.ArtifactName) + "\n"
  );

def is_cov:
  (blob | contains("cov-")) or (blob | contains("coverity"));

def is_bd:
  (blob | contains("detect.sh")) or (blob | contains("synopsys detect")) or (blob | contains("blackduck.url")) or (blob | contains("black duck"));

def delete_cov_vars:
  if .variables == null then
    .
  elif (.variables | type) == "!!map" then
    .variables |= with_entries(select((.key | test("^COVERITY_")) | not))
  elif (.variables | type) == "!!seq" then
    .variables |= map(select((.name // "" | test("^COVERITY_")) | not))
  else
    .
  end;

def merge_vars(new):
  if .variables == null then
    .variables = new
  elif (.variables | type) == "!!map" then
    .variables = (.variables * new)
  elif (.variables | type) == "!!seq" then
    .variables += (new | to_entries | map({"name": .key, "value": .value}))
  else
    .
  end;

if (has("steps") and (.steps | type) == "!!seq") then
  (.steps) as $orig
  | ($orig | to_entries | map(select(.value | is_cov)) | map(.key)) as $covIdx
  | ($orig | to_entries | map(select(.value | is_bd))  | map(.key)) as $bdIdx
  | ($orig | any(. | is_bd)) as $bdAlready

  # DEBUG: expose indices (printed if you run yq without -i; we’ll print via a separate command below)
  | delete_cov_vars
  | .steps = ($orig | map(select(is_cov | not)))
  | merge_vars(load(strenv(BD_VARS)))
  | (if $bdAlready then
       .
     else
       # inject after checkout (step 0), else append
       if (.steps | length) > 0 then
         .steps = (.steps[0:1] + load(strenv(BD_STEPS)) + .steps[1:])
       else
         .steps = load(strenv(BD_STEPS))
       end
     end)
else
  .
end
YQ

echo "Coverity step count BEFORE (bash contains cov-):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)cov-"))) | length' "${PIPELINE_FILE}" || true
echo "Black Duck step count BEFORE (bash contains detect.sh):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)detect\.sh"))) | length' "${PIPELINE_FILE}" || true

echo "Before hash:"; sha256sum "${PIPELINE_FILE}" || true
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"   # in-place single-file edit [1](https://github.com/mikefarah/yq/issues/1315)[4](https://linuxcommandlibrary.com/man/yq)
echo "After hash:"; sha256sum "${PIPELINE_FILE}" || true

echo "Coverity step count AFTER (bash contains cov-):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)cov-"))) | length' "${PIPELINE_FILE}" || true
echo "Black Duck step count AFTER (bash contains detect.sh):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)detect\.sh"))) | length' "${PIPELINE_FILE}" || true

rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check (ignore comments; should show NO real cov-* commands):"
grep -nE '^[^#]*\bcov-' -n "${PIPELINE_FILE}" || echo "✅ Coverity commands removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" || echo "✅ Black Duck present"
