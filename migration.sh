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

# If older attempts created multi-doc YAML, keep only doc 0 (prevents --- leftovers)
# eval-all can emit multiple docs separated by --- unless you select one. [1](https://github.com/mikefarah/yq/issues/1642)[2](https://stackoverflow.com/questions/70032588/use-yq-to-substitute-string-in-a-yaml-file)
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

# --- Prove yq can load the snippets (debug) ---
echo "BD_VARS path: ${BD_VARS}"
echo "BD_STEPS path: ${BD_STEPS}"
echo "Preview BD_VARS:"; cat "${BD_VARS}"
echo "Preview BD_STEPS (first 25 lines):"; sed -n '1,25p' "${BD_STEPS}"

# yq can load files via load(); -n creates a new doc, then we load the file. [3](https://linuxcommandlibrary.com/man/yq)[2](https://stackoverflow.com/questions/70032588/use-yq-to-substitute-string-in-a-yaml-file)
echo "yq load(BD_VARS) sanity:"
yq -n 'load(strenv(BD_VARS))' >/dev/null && echo "✅ BD_VARS load OK"
echo "yq load(BD_STEPS) sanity:"
yq -n 'load(strenv(BD_STEPS))' >/dev/null && echo "✅ BD_STEPS load OK"

# --- yq program: ALWAYS remove coverity steps + vars; inject BD if missing ---
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

def is_cov:
  step_text
  | test("coverity|\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b|\\bcov-import-scm\\b|\\bcov-run-desktop\\b|\\bcov-manage-im\\b");

def has_bd:
  step_text
  | test("black duck|synopsys detect|detect\\.sh|blackduck\\.url");

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
  | ($orig | to_entries | map(select(.value | is_cov)) | .[0].key) as $firstCovIdx
  | ($orig | map(select(is_cov | not))) as $noCovSteps
  | ($orig | any(. | has_bd)) as $bdAlready

  # remove COVERITY_ vars + merge BD vars always
  | delete_cov_vars
  | merge_vars(load(strenv(BD_VARS)))

  # steps:
  # - always remove coverity
  # - inject BD only if missing
  | if $bdAlready then
      .steps = $noCovSteps
    else
      .steps = (
        if $firstCovIdx == null then
          $noCovSteps + load(strenv(BD_STEPS))
        else
          ($orig[0:$firstCovIdx] + load(strenv(BD_STEPS)) + ($orig[$firstCovIdx:] | map(select(is_cov | not))))
        end
      )
    end
else
  .
end
YQ

echo "Before hash:"; sha256sum "${PIPELINE_FILE}" || true

# Edit the pipeline in place (correct for single-file edits). [2](https://stackoverflow.com/questions/70032588/use-yq-to-substitute-string-in-a-yaml-file)[4](https://github.com/mikefarah/yq/issues/1315)
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"

echo "After hash:"; sha256sum "${PIPELINE_FILE}" || true
echo "Diff vs backup:"
diff -u "${PIPELINE_FILE}.bak" "${PIPELINE_FILE}" || echo "(no diff)"

# Cleanup
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check (ignore comments; should show NO real cov-* commands):"
grep -nE "^[^#]*\\bcov-build\\b|^[^#]*\\bcov-analyze\\b|^[^#]*\\bcov-format-errors\\b|^[^#]*\\bcov-commit-defects\\b" -n "${PIPELINE_FILE}" \
  || echo "✅ Coverity commands removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" \
  || echo "✅ Black Duck present"

echo "Post-check (single-document YAML; no ---):"
grep -n '^---$' "${PIPELINE_FILE}" || echo "✅ single-document YAML"
