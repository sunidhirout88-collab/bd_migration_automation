#!/usr/bin/env bash
set -euo pipefail

PIPELINE_FILE="azure-pipelines.yml"
FILE="${PIPELINE_FILE}"
ls -la target
find target -maxdepth 2 -name "azure-pipelines.y*ml" -print
yq --version || yq -V
cd target/
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq (Mike Farah, v4+) is required."
  echo "Install:"
  echo "  macOS: brew install yq"
  echo "  Linux: https://github.com/mikefarah/yq/#install"
  exit 1
fi

# --- Black Duck variables (map) ---
BD_VARS="$(mktemp)"
cat > "${BD_VARS}" <<'YAML'
BLACKDUCK_URL: 'https://blackduck.mycompany.com'
BD_PROJECT: 'my-app'
BD_VERSION: '$(Build.SourceBranchName)'
DETECT_VERSION: 'latest'   # or pin e.g. 9.10.0
YAML

# --- Black Duck steps (sequence) - EXACTLY as you provided ---
BD_STEPS="$(mktemp)"
cat > "${BD_STEPS}" <<'YAML'
- checkout: self
  fetchDepth: 0

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

# --- Coverity step detection (tailored to your snippet) ---
# It matches:
# - cov-build/cov-analyze/cov-format-errors/cov-commit-defects (and other cov-* tools)
# - the word "coverity" in bash/script text
# - displayName containing "coverity"
COVERITY_EXPR='
def is_coverity_step:
  (
    ((.bash // .script // "") | ascii_downcase)
    | test("coverity|\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b|\\bcov-import-scm\\b|\\bcov-run-desktop\\b|\\bcov-manage-im\\b")
  )
  or ((.displayName // "") | ascii_downcase | test("\\bcoverity\\b"));
'

# --- Merge vars into current node (job-level variables if we are in a job) ---
MERGE_VARS_FN='
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
'

# --- Delete coverity vars (COVERITY_*) at the same scope ---
DELETE_COV_VARS_FN='
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
'

# --- Main transformation ---
# For any YAML map that has steps: [ ... ],
# if it contains any coverity steps:
#  1) remove coverity steps
#  2) remove COVERITY_* variables at same level
#  3) merge BLACKDUCK_* vars at same level
#  4) insert Black Duck steps at the position of the first removed coverity step (keeps ordering)
YQ_PROG="$(mktemp)"

cat > "${YQ_PROG}" <<'YQ'
def is_coverity_step:
  (
    ((.bash // .script // "") | ascii_downcase)
    | test("coverity|\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b|\\bcov-import-scm\\b|\\bcov-run-desktop\\b|\\bcov-manage-im\\b")
  )
  or ((.displayName // "") | ascii_downcase | test("\\bcoverity\\b"));

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

def already_has_blackduck:
  (
    (.steps // [])
    | map(
        ((.displayName // "") | ascii_downcase)
        + " " +
        ((.bash // .script // "") | ascii_downcase)
      )
    | any(test("black duck|synopsys detect|detect\\.sh|blackduck\\.url"))
  );

def inject_blackduck_preserving_position:
  (.steps | to_entries | map(select(.value | is_coverity_step)) | .[0].key) as $firstIdx
  | (if $firstIdx == null then . else
      (.steps[0:$firstIdx]) as $prefix
      | (.steps[$firstIdx:] | map(select(is_coverity_step | not))) as $suffix
      | .steps = ($prefix + load(strenv(BD_STEPS)) + $suffix)
    end);

def transform_node:
  if (type == "!!map" and has("steps") and (.steps | type == "!!seq")) then
    if (.steps | any(is_coverity_step)) then
      delete_coverity_vars
      | merge_vars(load(strenv(BD_VARS)))
      | (if already_has_blackduck then
           .steps |= map(select(is_coverity_step | not))
         else
           inject_blackduck_preserving_position
         end)
    else
      .
    end
  else
    .
  end;

walk(transform_node)
YQ

# Use yq v4 syntax explicitly
yq eval -i -f "${YQ_PROG}" "${FILE}"

rm -f "${YQ_PROG}"
rm -f "${BD_VARS}" "${BD_STEPS}"

echo "Done. Coverity steps removed, COVERITY_* variables removed, and Black Duck steps injected in: ${FILE}"
