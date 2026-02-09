#!/usr/bin/env bash
set -euo pipefail

# ---------- Resolve script path safely ----------
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

echo "SCRIPT PATH: ${SCRIPT_PATH}"
echo "SCRIPT HASH: $(sha256sum "${SCRIPT_PATH}" | awk '{print $1}')"

# ---------- Move to folder containing azure-pipelines.yml ----------
if [[ -f "${SCRIPT_DIR}/target/azure-pipelines.yml" ]]; then
  cd "${SCRIPT_DIR}/target"
elif [[ -f "${SCRIPT_DIR}/azure-pipelines.yml" ]]; then
  cd "${SCRIPT_DIR}"
else
  echo "ERROR: Cannot locate azure-pipelines.yml in ${SCRIPT_DIR} or ${SCRIPT_DIR}/target"
  exit 1
fi

PIPELINE_FILE="azure-pipelines.yml"

# ---------- Prereqs ----------
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq (Mike Farah, v4+) is required."
  exit 1
fi

echo "Using yq: $(yq --version)"
echo "PWD: $(pwd)"
echo "Editing: ${PIPELINE_FILE}"

# ---------- Backup ----------
cp -p "${PIPELINE_FILE}" "${PIPELINE_FILE}.bak"

# Keep only the first YAML document (guards against multi-doc leftovers)
yq e -i 'select(di == 0)' "${PIPELINE_FILE}"

# ---------- Black Duck variables (map) ----------
BD_VARS="$(mktemp)"
cat > "${BD_VARS}" <<'YAML'
BLACKDUCK_URL: 'https://blackduck.mycompany.com'
BD_PROJECT: 'my-app'
BD_VERSION: '$(Build.SourceBranchName)'
DETECT_VERSION: 'latest'
YAML

# ---------- Black Duck steps (sequence) ----------
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

# ---------- Debug counts BEFORE (non-fatal) ----------
echo "Coverity bash-step count BEFORE (cov- in .bash):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)cov-"))) | length' "${PIPELINE_FILE}" || true

echo "BlackDuck detect-step count BEFORE (detect.sh in .bash):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)detect\.sh"))) | length' "${PIPELINE_FILE}" || true

echo "Before hash:"; sha256sum "${PIPELINE_FILE}" || true

# ---------- yq program (NO '#' comments inside this block) ----------
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
def low(x): (x // "" | tostring | ascii_downcase);

def is_cov_step:
  (
    (low(.displayName) | contains("coverity"))
    or (low(.bash) | contains("cov-"))
    or (low(.script) | contains("cov-"))
    or (low(.pwsh) | contains("cov-"))
    or (low(.powershell) | contains("cov-"))
    or (low(.inputs.artifactName) | contains("coverity"))
    or (low(.inputs.ArtifactName) | contains("coverity"))
    or (low(.inputs.pathToPublish) | contains("coverity") or contains("$(coverity") or contains("$(coverity_")))
    or (low(.inputs.PathtoPublish) | contains("coverity") or contains("$(coverity") or contains("$(coverity_")))
  );

def has_bd_steps:
  (.steps // [])
  | any(
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
  delete_cov_vars
  | .steps |= map(select(is_cov_step | not))
  | merge_vars(load(strenv(BD_VARS)))
  | (if has_bd_steps then
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

# ---------- ADDITION: Debug block around yq eval (this is what you asked for) ----------
echo "=== DEBUG: yq program file ==="
wc -l "$YQ_PROG"
sed -n '1,160p' "$YQ_PROG"

echo "=== DEBUG: running yq eval now ==="
set -x
yq eval -i -f "$YQ_PROG" "$PIPELINE_FILE" 2>yq_error.log || {
  set +x
  echo "❌ yq eval failed. Error output:"
  cat yq_error.log
  echo "=== DEBUG: yq program (full) ==="
  cat "$YQ_PROG"
  echo "=== DEBUG: pipeline excerpt (first 120 lines) ==="
  sed -n '1,120p' "$PIPELINE_FILE"
  exit 1
}
set +x

echo "After hash:"; sha256sum "${PIPELINE_FILE}" || true

# ---------- Debug counts AFTER (non-fatal) ----------
echo "Coverity bash-step count AFTER (cov- in .bash):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)cov-"))) | length' "${PIPELINE_FILE}" || true

echo "BlackDuck detect-step count AFTER (detect.sh in .bash):"
yq e '(.steps // []) | map(select((.bash // "") | test("(?i)detect\.sh"))) | length' "${PIPELINE_FILE}" || true

# ---------- Cleanup ----------
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}" yq_error.log

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

# ---------- Post-checks (accurate) ----------
echo "Post-check Coverity (should be EMPTY):"
if grep -nE '^[^#]*\bcov-' -n "${PIPELINE_FILE}"; then
  echo "❌ Coverity still present"
else
  echo "✅ Coverity removed"
fi

echo "Post-check Black Duck (should show detect.sh or Black Duck Scan):"
if grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}"; then
  echo "✅ Black Duck present"
else
  echo "❌ Black Duck NOT found"
fi
