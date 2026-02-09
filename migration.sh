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

# Keep only first YAML document (protects against old eval-all multi-doc output). [3](https://github.com/mikefarah/yq/issues/1642)[4](https://unix.stackexchange.com/questions/561460/how-to-print-path-and-key-values-of-json-file)
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

# --- yq transformation program (FIELD-BASED + contains(), matches your YAML reliably) ---
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
def low(x): (x // "" | tostring | ascii_downcase);

# Coverity step detection for your exact pipeline:
# - bash/script contains cov-*
# - displayName contains "coverity"
# - publish inputs/artifactName include coverity
def is_cov:
  (
    (low(.displayName) | contains("coverity"))
    or (low(.bash) | contains("cov-"))
    or (low(.script) | contains("cov-"))
    or (low(.pwsh) | contains("cov-"))
    or (low(.powershell) | contains("cov-"))
    or (low(.inputs.pathToPublish) | contains("coverity"))
    or (low(.inputs.PathtoPublish) | contains("coverity"))
    or (low(.inputs.artifactName) | contains("coverity"))
    or (low(.inputs.ArtifactName) | contains("coverity"))
  );

# Black Duck detection
def is_bd:
  (
    (low(.displayName) | contains("black duck") or contains("synopsys detect"))
    or (low(.bash) | contains("detect.sh") or contains("blackduck.url"))
    or (low(.script) | contains("detect.sh") or contains("blackduck.url"))
  );

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

  # Always remove Coverity vars + Coverity steps
  | delete_cov_vars
  | .steps = ($orig | map(select(is_cov | not)))

  # Always merge BD vars
  | merge_vars(load(strenv(BD_VARS)))

  # Inject BD steps only if missing: insert after first step (checkout), else append
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

# Apply in-place edit (right pattern for single file). [1](https://github.com/mikefarah/yq/issues/1315)[2](https://linuxcommandlibrary.com/man/yq)
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"

# Cleanup
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check (ignore comments; should show NO real cov-* commands):"
grep -nE '^[^#]*\bcov-' -n "${PIPELINE_FILE}" || echo "✅ Coverity commands removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" || echo "✅ Black Duck present"
