#!/usr/bin/env bash
set -euo pipefail

# If azure-pipelines.yml is inside target/
cd target/

PIPELINE_FILE="azure-pipelines.yml"
SCRIPT_SELF="../migration.sh"   # adjust if you store it elsewhere

if [[ ! -f "${PIPELINE_FILE}" ]]; then
  echo "ERROR: Pipeline file not found: ${PIPELINE_FILE}"
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq (Mike Farah, v4+) is required."
  exit 1
fi

echo "Using yq: $(yq --version)"
echo "PWD: $(pwd)"
echo "Editing: ${PIPELINE_FILE}"

# --- Prove which script is running (hash + first lines) ---
if [[ -f "${SCRIPT_SELF}" ]]; then
  echo "SCRIPT HASH: $(sha256sum "${SCRIPT_SELF}" | awk '{print $1}')"
  echo "SCRIPT HEAD:"
  sed -n '1,15p' "${SCRIPT_SELF}"
else
  echo "WARN: Cannot find ${SCRIPT_SELF} to print script hash (adjust SCRIPT_SELF path)."
fi

# --- Backup ---
cp -p "${PIPELINE_FILE}" "${PIPELINE_FILE}.bak"

# Keep only first YAML document (avoid multi-doc leftovers from older eval-all usage) [3](https://github.com/mikefarah/yq/issues/1642)[4](https://stackoverflow.com/questions/70032588/use-yq-to-substitute-string-in-a-yaml-file)
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

# ---- yq program tailored to YOUR Coverity YAML ----
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
def low(x): (x // "" | tostring | ascii_downcase);

# A step "blob" covering exactly the places Coverity appears in your YAML:
def blob:
  (
    low(.displayName) + "\n" +
    low(.task) + "\n" +
    low(.bash) + "\n" +
    low(.script) + "\n" +
    low(.pwsh) + "\n" +
    low(.powershell) + "\n" +
    low(.inputs.pathToPublish) + "\n" +
    low(.inputs.PathtoPublish) + "\n" +
    low(.inputs.artifactName) + "\n" +
    low(.inputs.ArtifactName) + "\n" +
    low((.inputs // {}) | tostring)
  );

def is_cov:
  (
    (blob | contains("cov-"))
    or (blob | contains("coverity"))
    or (blob | contains("$(coverity"))
    or (blob | contains("$(coverity_"))
  );

def is_bd:
  (
    (blob | contains("detect.sh"))
    or (blob | contains("synopsys detect"))
    or (blob | contains("blackduck.url"))
    or (blob | contains("black duck"))
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

  # 1) Remove COVERITY_* vars
  | delete_cov_vars

  # 2) Remove Coverity steps
  | .steps = ($orig | map(select(is_cov | not)))

  # 3) Merge BD vars
  | merge_vars(load(strenv(BD_VARS)))

  # 4) Inject BD steps only if missing (insert right after checkout step)
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

# --- Detection proof before edit ---
echo "Coverity step count BEFORE:"
yq e '(.steps // []) | map(select(((.bash // "" ) | ascii_downcase) | contains("cov-") )) | length' "${PIPELINE_FILE}"
echo "Black Duck step count BEFORE:"
yq e '(.steps // []) | map(select(((.bash // "" ) | ascii_downcase) | contains("detect.sh") )) | length' "${PIPELINE_FILE}"

echo "Before hash:"; sha256sum "${PIPELINE_FILE}" || true
yq eval -i -f "${YQ_PROG}" "${PIPELINE_FILE}"  # in-place edit recommended [1](https://github.com/mikefarah/yq/issues/1315)[2](https://linuxcommandlibrary.com/man/yq)
echo "After hash:"; sha256sum "${PIPELINE_FILE}" || true

echo "Diff vs backup:"
diff -u "${PIPELINE_FILE}.bak" "${PIPELINE_FILE}" || true

# --- Detection proof after edit ---
echo "Coverity step count AFTER:"
yq e '(.steps // []) | map(select(((.bash // "" ) | ascii_downcase) | contains("cov-") )) | length' "${PIPELINE_FILE}"
echo "Black Duck step count AFTER:"
yq e '(.steps // []) | map(select(((.bash // "" ) | ascii_downcase) | contains("detect.sh") )) | length' "${PIPELINE_FILE}"

# Cleanup temp files
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

echo "Post-check (ignore comments; should show NO real cov-* commands):"
grep -nE '^[^#]*\bcov-' -n "${PIPELINE_FILE}" || echo "✅ Coverity commands removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" || echo "✅ Black Duck present"
