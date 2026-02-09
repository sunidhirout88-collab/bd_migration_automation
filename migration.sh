#!/usr/bin/env bash
set -euo pipefail

PIPELINE_FILE="azure-pipelines.yml"

# YAML is inside target/
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

# Sanity checks
yq e 'has("steps")' "${PIPELINE_FILE}"
yq e '.steps | type' "${PIPELINE_FILE}"

# Backup
cp -p "${PIPELINE_FILE}" "${PIPELINE_FILE}.bak"

# Keep only first YAML document (protect against old eval-all multi-doc output) [2](https://github.com/mikefarah/yq/issues/1642)[3](https://stackoverflow.com/questions/70032588/use-yq-to-substitute-string-in-a-yaml-file)
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

# Optional: prove load() works (uses env var + load, supported in yq v4) [4](https://linuxcommandlibrary.com/man/yq)[3](https://stackoverflow.com/questions/70032588/use-yq-to-substitute-string-in-a-yaml-file)
yq -n 'load(strenv(BD_VARS))' >/dev/null
yq -n 'load(strenv(BD_STEPS))' >/dev/null

# --- yq transformation program (robust Coverity matching) ---
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
def lower(x): (x // "") | tostring | ascii_downcase;

# Match Coverity by inspecting the places it actually appears in Azure Pipelines YAML:
# - bash/script blocks (cov-build/cov-analyze/etc)
# - displayName containing coverity
# - PublishBuildArtifacts inputs using coverity names/paths
def is_cov:
  (
    (lower(.displayName) | test("\\bcoverity\\b"))
    or (lower(.task) | test("\\bcoverity\\b"))
    or (lower(.bash) | test("\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b"))
    or (lower(.script) | test("\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b"))
    or (lower(.pwsh) | test("\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b"))
    or (lower(.powershell) | test("\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b"))
    or (lower(.inputs.pathToPublish) | test("coverity|\\$\\(coverity_"))
    or (lower(.inputs.PathtoPublish) | test("coverity|\\$\\(coverity_"))
    or (lower(.inputs.artifactName) | test("\\bcoverity\\b"))
    or (lower(.inputs.ArtifactName) | test("\\bcoverity\\b"))
  );

def is_bd:
  (
    (lower(.displayName) | test("black duck|synopsys detect"))
    or (lower(.bash) | test("detect\\.sh|blackduck\\.url|synopsys detect"))
    or (lower(.script) | test("detect\\.sh|blackduck\\.url|synopsys detect"))
    or ((.inputs // {}) | tostring | ascii_downcase | test("blackduck|detect\\.sh|synopsys"))
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
  | ($orig | to_entries | map(select(.value | is_cov)) | .[0].key) as $firstCovIdx

  # Always remove COVERITY_* variables and merge BD vars
  | delete_cov_vars
  | merge_vars(load(strenv(BD_VARS)))

  # Remove Coverity steps everywhere
  | (.steps = ($orig | map(select(is_cov | not))))

  # Inject BD only if missing
  | (if $bdAlready then
       .
     else
       if $firstCovIdx == null then
         .steps = (.steps + load(strenv(BD_STEPS)))
       else
         .steps = (
           $orig[0:$firstCovIdx]
           + load(strenv(BD_STEPS))
           + ($orig[$firstCovIdx:] | map(select(is_cov | not)))
         )
       end
     end)
else
  .
end
YQ

if [[ ! -s "${YQ_PROG}" ]]; then
  echo "ERROR: YQ program file is empty: ${YQ_PROG}"
  exit 1
fi

echo "Before hash:"; sha256sum "${PIPELINE_FILE}" || true
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"   # in-place edit is the intended pattern [1](https://github.com/mikefarah/yq/issues/1315)[4](https://linuxcommandlibrary.com/man/yq)
echo "After hash:"; sha256sum "${PIPELINE_FILE}" || true

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

echo "Post-check (single-document YAML; no ---):"
grep -n '^---$' "${PIPELINE_FILE}" || echo "✅ single-document YAML"
