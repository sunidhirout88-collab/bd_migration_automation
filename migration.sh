set -euo pipefail

REPO_URL="https://github.com/sunidhirout88-collab/blackduck_migration_test.git"
BRANCH="blackduck_cli"

rm -rf target
git clone --branch "${BRANCH}" "${REPO_URL}" target
cd target

# Find the pipeline YAML
PIPELINE_FILE="$(find . -maxdepth 4 -type f \( -name "azure-pipelines.yml" -o -name "azure-pipelines.yaml" \) | head -n 1)"
if [[ -z "${PIPELINE_FILE}" ]]; then
  echo "ERROR: No azure-pipelines.yml found."
  find . -maxdepth 6 -type f -name "*.yml" -o -name "*.yaml" | head -n 200
  exit 1
fi
PIPELINE_FILE="${PIPELINE_FILE#./}"
echo "Using pipeline: ${PIPELINE_FILE}"

# ...create SCRIPT_PATH + heredoc python here...

python3 "${SCRIPT_PATH}" "${PIPELINE_FILE}" --in-place
