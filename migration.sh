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

# Sanity checks
yq e 'has("steps")' "${PIPELINE_FILE}"
yq e '.steps | type' "${PIPELINE_FILE}"

# Backup
cp -p "${PIPELINE_FILE}" "${PIPELINE_FILE}.bak"

# If prior runs created multi-document YAML (---), keep only doc 0
# (eval-all can output multiple documents unless you explicitly select one) [2](https://docs.zarf.dev/commands/zarf_tools_yq_eval-all/)[3](https://linuxcommandlibrary.com/man/yq)
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

# --- yq program: ALWAYS remove Coverity; inject BD only if missing ---
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
def step_text:
  (
    (.displayName // "") + "\n" +
    (.task // "") + "\n" +
    (.bash // "") + "\n" +
    (.script // "") + "\n" +
    (.pwsh // "") + "\n" +
    (.powershell // "") + "\n" +
    (.inputs.script // "") + "\n" +
    (.inputs.inlineScript // "") + "\n" +
    (.inputs.arguments // "") + "\n" +
    ((.inputs // {}) | tostring)
  ) | ascii_downcase;

def is_coverity_any:
  step_text
  | test("coverity|\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b|\\bcov-import-scm\\b|\\bcov-run-desktop\\b|\\bcov-manage-im\\b");

def already_has_blackduck:
  (
    (.steps // [])
    | map(
        (
          (.displayName // "") + " " +
          (.bash // .script // .pwsh // .powershell // "") + " " +
          (.inputs.script // .inputs.inlineScript // "") + " " +
          ((.inputs // {}) | tostring)
        ) | ascii_downcase
      )
    | any(test("black duck|synopsys detect|detect\\.sh|blackduck\\.url"))
  );

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

def delete_coverity_vars:
  if .variables == null then
    .
  elif (.variables | type) == "!!map" then
    .variables |= with_entries(select((.key | test("^COVERITY_")) | not))
  elif (.variables | type) == "!!seq" then
    .variables |= map(select((.name // "" | test("^COVERITY_")) | not))
  else
    .
  end;

def remove_coverity_steps:
  .steps |= map(select(is_coverity_any | not));

def inject_bd_at_first_cov_or_end:
  (
    (.steps | to_entries | map(select(.value | is_coverity_any)) | .[0].key)
  ) as $firstIdx
  | if $firstIdx == null then
      .steps = (.steps + load(strenv(BD_STEPS)))
    else
      (.steps[0:$firstIdx]) as $prefix
      | (.steps[$firstIdx:]) as $tail
      | .steps = ($prefix + load(strenv(BD_STEPS)) + $tail)
    end;

if (has("steps") and (.steps | type == "!!seq")) then
  # Always remove Coverity vars + steps (if any)
  delete_coverity_vars
  | remove_coverity_steps
  # Always merge BD vars (safe even if already present)
  | merge_vars(load(strenv(BD_VARS)))
  # Inject BD steps only if missing
  | (if already_has_blackduck then . else inject_bd_at_first_cov_or_end end)
else
  .
end
YQ

# ✅ Correct single-file in-place edit. This is the intended pattern for editing YAML files. [1](https://sleeplessbeastie.eu/2024/01/26/how-to-work-with-yaml-files/)[2](https://docs.zarf.dev/commands/zarf_tools_yq_eval-all/)
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"

# Cleanup
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check (ignore comments; should show NO real cov-* commands):"
grep -nE "^[^#]*cov-build|^[^#]*cov-analyze|^[^#]*cov-format-errors|^[^#]*cov-commit-defects" -n "${PIPELINE_FILE}" \
  || echo "✅ Coverity commands removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" \
  || echo "❌ Black Duck not found (unexpected)"

echo "Post-check (single-document YAML; no ---):"
grep -n '^---$' "${PIPELINE_FILE}" || echo "✅ single-document YAML"
