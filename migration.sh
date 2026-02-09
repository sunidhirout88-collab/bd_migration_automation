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

# Keep only first YAML document (protect against old eval-all multi-doc output) [5](https://github.com/mikefarah/yq/issues/1642)[6](https://stackoverflow.com/questions/70032588/use-yq-to-substitute-string-in-a-yaml-file)
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

# --- yq transformation program ---
# Uses recursive descent to scan all string scalars within each step (covers multiline bash: | blocks). [1](https://deepwiki.com/mikefarah/yq)[2](https://nonbleedingedge.com/cheatsheets/yq.html)
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
def step_has(re):
  (
    [ .. | select(tag == "!!str") | ascii_downcase ]
    | any(test(re))
  );

# SUPER robust: any mention of cov-* or coverity anywhere in the step
def is_cov:
  step_has("coverity|cov-");

# BD detection
def is_bd:
  step_has("black duck|synopsys detect|detect\\.sh|blackduck\\.url|blackduck\\.api\\.token");

def delete_cov_vars:
  if .variables == null then
    .
  elif (.variables | type) == "!!map" then
    .variables |= with_entries(select(((.key | tostring) | test("^COVERITY_")) | not))
  elif (.variables | type) == "!!seq" then
    .variables |= map(select((((.name // "") | tostring) | test("^COVERITY_")) | not))
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

def first_cov_idx(steps):
  (steps | to_entries | map(select(.value | is_cov)) | .[0].key);

if (has("steps") and (.steps | type) == "!!seq") then
  (.steps) as $orig
  | ($orig | any(. | is_bd)) as $bdAlready
  | (first_cov_idx($orig)) as $covIdx

  # 1) Always remove COVERITY_* vars and merge BD vars
  | delete_cov_vars
  | merge_vars(load(strenv(BD_VARS)))

  # 2) Always remove Coverity steps
  | (.steps = ($orig | map(select(is_cov | not))))

  # 3) Inject BD steps only if missing
  | (if $bdAlready then
       .
     else
       if $covIdx == null then
         .steps = (.steps + load(strenv(BD_STEPS)))
       else
         .steps = (
           $orig[0:$covIdx]
           + load(strenv(BD_STEPS))
           + ($orig[$covIdx:] | map(select(is_cov | not)))
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

# In-place edit is the intended yq pattern for updating a single YAML file. [3](https://github.com/mikefarah/yq/issues/1315)[4](https://linuxcommandlibrary.com/man/yq)
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"

echo "After hash:"; sha256sum "${PIPELINE_FILE}" || true

# Cleanup
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check (ignore comments; should show NO real cov-* commands):"
grep -nE '^[^#]*\bcov-' -n "${PIPELINE_FILE}" || echo "✅ Coverity commands removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" || echo "❌ Black Duck not found (unexpected)"

echo "Post-check (single-document YAML; no ---):"
grep -n '^---$' "${PIPELINE_FILE}" || echo "✅ single-document YAML"
