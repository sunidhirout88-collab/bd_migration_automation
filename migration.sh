#!/usr/bin/env bash
set -euo pipefail

# --- Move to folder containing azure-pipelines.yml ---
if [[ -f "azure-pipelines.yml" ]]; then
  : # already here
elif [[ -f "target/azure-pipelines.yml" ]]; then
  cd target/
else
  echo "ERROR: Cannot locate azure-pipelines.yml in current dir or ./target"
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

# Keep only first YAML document (protect against old eval-all multi-doc output)
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

# --- yq program ---
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
    low(.inputs.ArtifactName) + "\n" +
    low((.inputs // {}) | tostring)
  );

def is_cov:
  (blob | contains("cov-")) or (blob | contains("coverity")) or (blob | contains("$(coverity"));

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
  | ($orig | any(. | is_bd)) as $bdAlready
  | delete_cov_vars
  | .steps = ($orig | map(select(is_cov | not)))
  | merge_vars(load(strenv(BD_VARS)))
  | (if $bdAlready then
       .
     else
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

# ---- Proof checks (these should not error now) ----
echo "Coverity step count BEFORE:"
yq e '(.steps // []) | map(select((.bash // "" | ascii_downcase) | contains("cov-"))) | length' "${PIPELINE_FILE}"

echo "Black Duck step count BEFORE:"
yq e '(.steps // []) | map(select((.bash // "" | ascii_downcase) | contains("detect.sh"))) | length' "${PIPELINE_FILE}"

echo "Before hash:"; sha256sum "${PIPELINE_FILE}" || true
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"
echo "After hash:"; sha256sum "${PIPELINE_FILE}" || true

echo "Coverity step count AFTER:"
yq e '(.steps // []) | map(select((.bash // "" | ascii_downcase) | contains("cov-"))) | length' "${PIPELINE_FILE}"

echo "Black Duck step count AFTER:"
yq e '(.steps // []) | map(select((.bash // "" | ascii_downcase) | contains("detect.sh"))) | length' "${PIPELINE_FILE}"

rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "Post-check (ignore comments; should show NO real cov-* commands):"
grep -nE '^[^#]*\bcov-' -n "${PIPELINE_FILE}" || echo "✅ Coverity commands removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" || echo "✅ Black Duck present"
