#!/usr/bin/env bash
set -euo pipefail

PIPELINE_FILE="azure-pipelines.yml"
cd target/

if [[ ! -f "${PIPELINE_FILE}" ]]; then
  echo "ERROR: Pipeline file not found: ${PIPELINE_FILE}"
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq (Mike Farah, v4+) is required."
  exit 1
fi

echo "Using yq: $(yq --version)"
echo "Updating: ${PIPELINE_FILE}"

# Backup
cp -p "${PIPELINE_FILE}" "${PIPELINE_FILE}.bak"

# If older runs created multi-doc YAML (---), keep only the first doc. [3](https://github.com/mikefarah/yq/issues/1642)[4](https://stackoverflow.com/questions/70032588/use-yq-to-substitute-string-in-a-yaml-file)
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

# --- yq program (matches YOUR Coverity format) ---
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
def s(x): (x // "" | tostring | ascii_downcase);

# Build a search blob from the fields where Coverity appears in your YAML:
# - bash/script text includes cov-build etc
# - displayName includes "Coverity ..."
# - publish steps include artifactName/pathToPublish containing coverity or $(COVERITY_...)
def step_blob:
  (
    s(.displayName) + "\n" +
    s(.task) + "\n" +
    s(.bash) + "\n" +
    s(.script) + "\n" +
    s(.pwsh) + "\n" +
    s(.powershell) + "\n" +
    s(.inputs.pathToPublish) + "\n" +
    s(.inputs.PathtoPublish) + "\n" +
    s(.inputs.artifactName) + "\n" +
    s(.inputs.ArtifactName) + "\n" +
    s((.inputs // {}) | tostring)
  );

def is_cov:
  step_blob | test("\\bcov-\\b|\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcoverity\\b|\\$\\(coverity_|\\$\\(coverity|\\$\\(coverity_|\\$\\(coverity");

def is_bd:
  step_blob | test("black duck|synopsys detect|detect\\.sh|blackduck\\.url|blackduck\\.api\\.token");

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

  # Always remove COVERITY_* variables and Coverity steps
  | delete_cov_vars
  | .steps = ($orig | map(select(is_cov | not)))

  # Always merge BD vars
  | merge_vars(load(strenv(BD_VARS)))

  # Inject BD steps only if missing (insert after checkout if present)
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

# Apply in-place edit (correct for single YAML file update). [1](https://github.com/mikefarah/yq/issues/1315)[2](https://linuxcommandlibrary.com/man/yq)
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"

# Cleanup
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check (ignore comments; should show NO real cov-* commands):"
grep -nE '^[^#]*\bcov-build\b|^[^#]*\bcov-analyze\b|^[^#]*\bcov-format-errors\b|^[^#]*\bcov-commit-defects\b' -n "${PIPELINE_FILE}" \
  || echo "✅ Coverity commands removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" \
  || echo "✅ Black Duck present"
