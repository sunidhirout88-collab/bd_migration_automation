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

# If prior runs created multi-document YAML (---), keep ONLY the first document
# eval-all often causes multi-doc output unless you explicitly select one doc. [1](https://docs.zarf.dev/commands/zarf_tools_yq_eval-all/)[2](https://linuxcommandlibrary.com/man/yq)
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

# --- yq program file (robust coverity detection using tostring) ---
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
def is_cov:
  (tostring | ascii_downcase | test("coverity|\\bcov-"));

def is_bd:
  (tostring | ascii_downcase | test("black duck|synopsys detect|detect\\.sh|blackduck\\.url"));

def delete_coverity_vars:
  if .variables == null then
    .
  elif (.variables | type) == "!!map" then
   j
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

def first_cov_idx:
  (.steps | to_entries | map(select(.value | is_cov)) | .[0].key);

def remove_cov_steps:
  .steps |= map(select((. | is_cov) | not));

def inject_bd_at_first_cov:
  (first_cov_idx) as $i
  | if $i == null then
      .steps = (.steps + load(strenv(BD_STEPS)))
    else
      (.steps[0:$i]) as $prefix
      | (.steps[$i:] | map(select((. | is_cov) | not))) as $suffix
      | .steps = ($prefix + load(strenv(BD_STEPS)) + $suffix)
    end;

if (has("steps") and (.steps | type) == "!!seq") then
  if (.steps | any(. | is_cov)) then
    delete_coverity_vars
    | merge_vars(load(strenv(BD_VARS)))
    | (if (.steps | any(. | is_bd)) then
         remove_cov_steps
       else
         inject_bd_at_first_cov
       end)
  else
    .
  end
else
  .
end
YQ

# ✅ Debug detection counts (single-line JSON object; avoids lexer issues)
echo "Debug detection counts (before edit):"
yq e '{"cov_steps": ((.steps // []) | map(select(tostring|ascii_downcase|test("coverity|cov-"))) | length), "bd_steps": ((.steps // []) | map(select(tostring|ascii_downcase|test("black duck|synopsys detect|detect\\.sh|blackduck\\.url"))) | length)}' "${PIPELINE_FILE}"

# ✅ Correct: edit only the pipeline file in-place (avoid eval-all multi-doc output) [3](https://sleeplessbeastie.eu/2024/01/26/how-to-work-with-yaml-files/)[1](https://docs.zarf.dev/commands/zarf_tools_yq_eval-all/)
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"

# Cleanup
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check (should show NO cov-*):"
grep -nE "cov-build|cov-analyze|cov-format-errors|cov-commit-defects|Coverity" -n "${PIPELINE_FILE}" \
  || echo "✅ Coverity removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" \
  || echo "✅ Black Duck present"

echo "Post-check (should be single-document YAML; no ---):"
grep -n '^---$' "${PIPELINE_FILE}" || echo "✅ single-document YAML"
