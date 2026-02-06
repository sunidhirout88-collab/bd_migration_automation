#!/usr/bin/env bash
set -euo pipefail

# --- Location of the pipeline YAML (adjust if needed) ---
PIPELINE_FILE="azure-pipelines.yml"

# If your script runs from repo root but the YAML is inside target/, keep this:
cd target/
# PIPELINE_FILE="azure-pipelines.yml"

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

# --- Backup ---
cp -p "${PIPELINE_FILE}" "${PIPELINE_FILE}.bak"

# --- Black Duck variables (map) ---
BD_VARS="$(mktemp)"
cat > "${BD_VARS}" <<'YAML'
BLACKDUCK_URL: 'https://blackduck.mycompany.com'
BD_PROJECT: 'my-app'
BD_VERSION: '$(Build.SourceBranchName)'
DETECT_VERSION: 'latest'   # or pin e.g. 9.10.0
YAML

# --- Black Duck steps (sequence) ---
# IMPORTANT: No checkout step here because your YAML already has one.
BD_STEPS="$(mktemp)"
cat > "${BD_STEPS}" <<'YAML'
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

export BD_VARS BD_STEPS

# --- yq program file (prevents lexer/quoting issues) ---
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
    (.inputs | tostring)
  ) | ascii_downcase;

def is_coverity_step:
  step_text
  | test("coverity|\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b|\\bcov-import-scm\\b|\\bcov-run-desktop\\b|\\bcov-manage-im\\b");

def is_coverity_publish:
  (
    ((.displayName // "") | ascii_downcase | test("publish coverity"))
    or ((.inputs.pathToPublish // "") | ascii_downcase | test("coverity|\\$\\(coverity_"))
    or ((.inputs.PathtoPublish // "") | ascii_downcase | test("coverity|\\$\\(coverity_"))
    or ((.inputs.artifactName // "") | ascii_downcase | test("\\bcoverity\\b"))
    or ((.inputs.ArtifactName // "") | ascii_downcase | test("\\bcoverity\\b"))
  );

def is_coverity_any:
  is_coverity_step or is_coverity_publish;

def already_has_blackduck:
  (
    (.steps // [])
    | map(
        (
          (.displayName // "") + " " +
          (.bash // .script // .pwsh // .powershell // "") + " " +
          (.inputs.script // .inputs.inlineScript // "")
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

def inject_blackduck_preserving_position:
  (.steps | to_entries | map(select(.value | is_coverity_any)) | .[0].key) as $firstIdx
  | (if $firstIdx == null then . else
      (.steps[0:$firstIdx]) as $prefix
      | (.steps[$firstIdx:] | map(select(is_coverity_any | not))) as $suffix
      | .steps = ($prefix + load(strenv(BD_STEPS)) + $suffix)
    end);

# --- Apply transformation at the pipeline/root level (your YAML uses top-level steps) ---
if (has("steps") and (.steps | type == "!!seq")) then
  if (.steps | any(. | is_coverity_any)) then
    delete_coverity_vars
    | merge_vars(load(strenv(BD_VARS)))
    | (if already_has_blackduck then
         .steps |= map(select(is_coverity_any | not))
       else
         inject_blackduck_preserving_position
       end)
  else
    .
  end
else
  .
end
YQ

# Execute yq transformation
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"
cat "${PIPELINE_FILE}"
# Cleanup
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check (should show NO cov-*):"
grep -nE "cov-build|cov-analyze|cov-format-errors|cov-commit-defects|Coverity" -n "${PIPELINE_FILE}" || echo "✅ Coverity removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" || echo "❌ Black Duck not found (unexpected)"
