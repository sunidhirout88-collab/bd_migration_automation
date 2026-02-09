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

yq e 'has("steps")' azure-pipelines.yml
yq e '.steps | type' azure-pipelines.yml



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
# --- yq program file (yq v4.5.2 compatible: no 'def') ---
YQ_PROG="$(mktemp)"
cat > "${YQ_PROG}" <<'YQ'
# Inputs:
#   fileIndex==0 -> pipeline YAML
#   fileIndex==1 -> BD_VARS (map)
#   fileIndex==2 -> BD_STEPS (seq)

select(fileIndex==0) as $p
| select(fileIndex==1) as $newVars
| select(fileIndex==2) as $newSteps
| $p
| (
    "coverity|\\bcov-build\\b|\\bcov-analyze\\b|\\bcov-format-errors\\b|\\bcov-commit-defects\\b|\\bcov-commit\\b|\\bcov-import-scm\\b|\\bcov-run-desktop\\b|\\bcov-manage-im\\b" as $covRe
    | "black duck|synopsys detect|detect\\.sh|blackduck\\.url" as $bdRe

    | if (has("steps") and (.steps | type) == "!!seq") then

        # --- Detect if any step looks like Coverity ---
        (
          (.steps // [])
          | map(
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
              ) | ascii_downcase
            )
          | any(test($covRe) or test("publish coverity"))
        ) as $hasCov

        # --- Detect if Black Duck already present ---
        | (
            (.steps // [])
            | map(
                (
                  (.displayName // "") + " " +
                  (.bash // .script // .pwsh // .powershell // "") + " " +
                  (.inputs.script // .inputs.inlineScript // "") + " " +
                  ((.inputs // {}) | tostring)
                ) | ascii_downcase
              )
            | any(test($bdRe))
          ) as $hasBD

        | if $hasCov then

            # --- Delete COVERITY_ variables (map or seq) ---
            (
              if .variables == null then
                .
              elif (.variables | type) == "!!map" then
                .variables |= with_entries(select((.key | test("^COVERITY_")) | not))
              elif (.variables | type) == "!!seq" then
                .variables |= map(select((.name // "" | test("^COVERITY_")) | not))
              else
                .
              end
            )

            # --- Merge in Black Duck vars (map or seq) ---
            | (
              if .variables == null then
                .variables = $newVars
              elif (.variables | type) == "!!map" then
                .variables = (.variables * $newVars)
              elif (.variables | type) == "!!seq" then
                .variables += ($newVars | to_entries | map({"name": .key, "value": .value}))
              else
                .
              end
            )

            # --- Remove Coverity steps (and optionally inject BD steps) ---
            | (
              # Find the index of the first Coverity-like step
              (
                (.steps // [])
                | to_entries
                | map(
                    select(
                      (
                        (
                          (.value.displayName // "") + "\n" +
                          (.value.task // "") + "\n" +
                          (.value.bash // "") + "\n" +
                          (.value.script // "") + "\n" +
                          (.value.pwsh // "") + "\n" +
                          (.value.powershell // "") + "\n" +
                          ((.value.inputs // {}) | tostring)
                        ) | ascii_downcase
                      )
                      | test($covRe)
                      or ((.value.displayName // "") | ascii_downcase | test("publish coverity"))
                      or (((.value.inputs.pathToPublish // "") + " " + (.value.inputs.PathtoPublish // "")) | ascii_downcase | test("coverity|\\$\\(coverity_"))
                      or (((.value.inputs.artifactName // "") + " " + (.value.inputs.ArtifactName // "")) | ascii_downcase | test("\\bcoverity\\b"))
                    )
                  )
                | .[0].key
              ) as $firstIdx

              | if $hasBD then
                  # If BD already exists: just remove Coverity-related steps everywhere
                  .steps |= map(
                    select(
                      (
                        (
                          (.displayName // "") + "\n" +
                          (.task // "") + "\n" +
                          (.bash // "") + "\n" +
                          (.script // "") + "\n" +
                          (.pwsh // "") + "\n" +
                          (.powershell // "") + "\n" +
                          ((.inputs // {}) | tostring)
                        ) | ascii_downcase
                      )
                      | test($covRe)
                      or ((.displayName // "") | ascii_downcase | test("publish coverity"))
                      or (((.inputs.pathToPublish // "") + " " + (.inputs.PathtoPublish // "")) | ascii_downcase | test("coverity|\\$\\(coverity_"))
                      or (((.inputs.artifactName // "") + " " + (.inputs.ArtifactName // "")) | ascii_downcase | test("\\bcoverity\\b"))
                      | not
                    )
                  )
                else
                  # Inject BD steps at first Coverity position; remove Coverity steps around it
                  if $firstIdx == null then
                    # No index found (unexpected since $hasCov true) — append BD steps
                    .steps = (.steps + $newSteps)
                  else
                    (.steps[0:$firstIdx]) as $prefix
                    | (
                        .steps[$firstIdx:]
                        | map(
                            select(
                              (
                                (
                                  (.displayName // "") + "\n" +
                                  (.task // "") + "\n" +
                                  (.bash // "") + "\n" +
                                  (.script // "") + "\n" +
                                  (.pwsh // "") + "\n" +
                                  (.powershell // "") + "\n" +
                                  ((.inputs // {}) | tostring)
                                ) | ascii_downcase
                              )
                              | test($covRe)
                              or ((.displayName // "") | ascii_downcase | test("publish coverity"))
                              or (((.inputs.pathToPublish // "") + " " + (.inputs.PathtoPublish // "")) | ascii_downcase | test("coverity|\\$\\(coverity_"))
                              or (((.inputs.artifactName // "") + " " + (.inputs.ArtifactName // "")) | ascii_downcase | test("\\bcoverity\\b"))
                              | not
                            )
                          )
                      ) as $suffix
                    | .steps = ($prefix + $newSteps + $suffix)
                  end
              end
            )

          else
            .
          end

      else
        .
      end
  )
YQ
``
# Execute yq transformation
# Execute yq transformation (safe for eval-all: write to temp then move)
TMP_OUT="$(mktemp)"
yq eval-all -f "${YQ_PROG}" "${PIPELINE_FILE}" "${BD_VARS}" "${BD_STEPS}" > "${TMP_OUT}"
mv "${TMP_OUT}" "${PIPELINE_FILE}"
cat "${PIPELINE_FILE}"
# Cleanup
rm -f "${BD_VARS}" "${BD_STEPS}" "${YQ_PROG}"

echo "✅ Done. Updated ${PIPELINE_FILE}"
echo "Backup saved as ${PIPELINE_FILE}.bak"

ls -la
cat azure-pipelines.yml
grep -nE '&gt;|&lt;|&amp;' your-script.sh || echo "✅ no html escapes"
echo "Post-check (should show NO cov-*):"
grep -nE "cov-build|cov-analyze|cov-format-errors|cov-commit-defects|Coverity" -n "${PIPELINE_FILE}" || echo "✅ Coverity removed"

echo "Post-check (should show Black Duck):"
grep -nE "Synopsys Detect|detect\.sh|Black Duck Scan" -n "${PIPELINE_FILE}" || echo "❌ Black Duck not found (unexpected)"
