#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <workflow1.yml> [<workflow2.yml> ...]" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage

for wf in "$@"; do
  [[ -f "$wf" ]] || { echo "File not found: $wf" >&2; exit 2; }

  cp -f "$wf" "$wf.bak"

  if grep -qE 'uses:\s*synopsys-sig/synopsys-action@' "$wf"; then
    echo "Migrating Polaris GitHub Action workflow → Black Duck SCA action: $wf"

    cat > "$wf" <<'YAML'
name: Black Duck SCA - GitHub Action
on:
  workflow_dispatch:

jobs:
  blackduck_sca:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Black Duck SCA - Security Scan
        uses: blackduck-inc/black-duck-security-scan@v2
        with:
          # Required (store these in GitHub → Settings → Secrets and variables → Actions)
          blackducksca_url: ${{ vars.BLACKDUCK_URL }}
          blackducksca_token: ${{ secrets.BLACKDUCK_TOKEN }}

          # Optional quality gate (fail on policy-severity); uncomment as needed:
          # blackducksca_scan_failure_severities: 'BLOCKER,CRITICAL'

          # Optional: enable PR comments (requires a PAT in secrets.GITHUB_TOKEN or a custom token)
          # blackducksca_prcomment_enabled: true
          # github_token: ${{ secrets.GITHUB_TOKEN }}

          # Optional: create & upload SARIF (and show findings in GitHub Advanced Security)
          # blackducksca_reports_sarif_create: true
          # blackducksca_upload_sarif_report: true
          # github_token: ${{ secrets.GITHUB_TOKEN }}

          # Optional: choose build status when policy violations are found (FAILURE|UNSTABLE|SUCCESS)
          # mark_build_status: 'FAILURE'
YAML

  elif grep -q -- "--stage polaris" "$wf"; then
    echo "Migrating Polaris Bridge CLI workflow → Black Duck SCA CLI: $wf"

    cat > "$wf" <<'YAML'
name: Black Duck SCA - CLI
on:
  workflow_dispatch:

jobs:
  blackduck_cli:
    runs-on: ubuntu-latest
    env:
      # Supply via GitHub → Settings → Secrets and variables → Actions
      BLACKDUCK_URL: ${{ vars.BLACKDUCK_URL }}
      BLACKDUCK_TOKEN: ${{ secrets.BLACKDUCK_TOKEN }}
    steps:
      - uses: actions/checkout@v4

      - name: Download Bridge CLI (Thin Client)
        run: |
          set -euo pipefail
          mkdir -p .ci-tools
          # TODO: Download Bridge Thin Client from your approved mirror and save as .ci-tools/bridge-cli
          # Example (placeholder): curl -fL "<APPROVED_URL>/bridge-cli-linux-x64" -o .ci-tools/bridge-cli
          # chmod +x .ci-tools/bridge-cli

      - name: Run Bridge CLI (Black Duck SCA)
        run: |
          set -euo pipefail
          # Pass token via environment variable recommended by Black Duck docs
          export BRIDGE_BLACKDUCKSCA_TOKEN="${BLACKDUCK_TOKEN}"
          # Run a Black Duck SCA scan (full vs PR/rapid handled by how you configure Detect; add flags as needed)
          ./.ci-tools/bridge-cli --stage blackducksca \
            blackducksca.url="${BLACKDUCK_URL}"
          # Optional quality gate example:
          # ./.ci-tools/bridge-cli --stage blackducksca \
          #   blackducksca.url="${BLACKDUCK_URL}" \
          #   blackducksca.scan.failure.severities=CRITICAL,HIGH
YAML

  else
    echo "Skipping (no recognizable Polaris plugin/CLI pattern): $wf"
  fi

done

echo "Done. Backups were saved as *.bak"
