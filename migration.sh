#!/usr/bin/env bash
set -euo pipefail

# CONFIG
REPO_DIR="${1:-$(pwd)}"
WORKFLOWS_DIR="$REPO_DIR/.github/workflows"
AUTO_COMMIT="${AUTO_COMMIT:-true}"           # set to "false" to skip commit/push
COMMIT_BRANCH="${COMMIT_BRANCH:-}"           # if set, checkout/create this branch before editing
COMMIT_MESSAGE="${COMMIT_MESSAGE:-migrate: Polaris → Black Duck SCA}"

# --- helpers ---
die() { echo "ERROR: $*"; exit 1; }
msg() { echo "==> $*"; }

[[ -d "$WORKFLOWS_DIR" ]] || die "No .github/workflows directory at $WORKFLOWS_DIR"

if [[ -n "$COMMIT_BRANCH" ]]; then
  msg "Checking out branch: $COMMIT_BRANCH"
  git -C "$REPO_DIR" checkout -B "$COMMIT_BRANCH"
fi

changed=false

migrate_plugin() {
  local f="$1"
  msg "Migrating (Plugin→Action): $f"
  cp -f "$f" "$f.bak"

  # Extract existing 'on:' section if present to preserve triggers
  awk '
    BEGIN{print "---"}
    /^on:/{flag=1}
    flag{print; if ($0 ~ /^[^[:space:]]/ && $0 !~ /^on:/ && NR>1) flag=0}
  ' "$f" > "$f.on.tmp" || true

  {
    # Use preserved triggers if found; otherwise default to workflow_dispatch
    if grep -q '^on:' "$f.on.tmp" 2>/dev/null; then
      sed -n '2,$p' "$f.on.tmp"
    else
      cat <<'TRIG'
on:
  workflow_dispatch:
TRIG
    fi

    cat <<'JOBS'

jobs:
  blackduck_sca:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Black Duck SCA - Security Scan
        uses: blackduck-inc/black-duck-security-scan@v2
        with:
          # Required (configure in GitHub → Settings → Secrets and variables → Actions)
          blackducksca_url: ${{ vars.BLACKDUCK_URL }}
          blackducksca_token: ${{ secrets.BLACKDUCK_TOKEN }}

          # Optional quality gate (fail on policy-severity); uncomment as needed:
          # blackducksca_scan_failure_severities: 'BLOCKER,CRITICAL'

          # Optional: PR comments (requires token)
          # blackducksca_prcomment_enabled: true
          # github_token: ${{ secrets.GITHUB_TOKEN }}

          # Optional: SARIF creation & upload (requires token)
          # blackducksca_reports_sarif_create: true
          # blackducksca_upload_sarif_report: true
          # github_token: ${{ secrets.GITHUB_TOKEN }}
JOBS
  } | awk 'NR==1{print "name: Black Duck SCA - GitHub Action"}1' > "$f.new"

  mv "$f.new" "$f"
  rm -f "$f.on.tmp"
  changed=true
}

migrate_cli() {
  local f="$1"
  msg "Migrating (CLI Polaris→CLI Black Duck SCA): $f"
  cp -f "$f" "$f.bak"

  # Preserve triggers if present.
  awk '
    BEGIN{print "---"}
    /^on:/{flag=1}
    flag{print; if ($0 ~ /^[^[:space:]]/ && $0 !~ /^on:/ && NR>1) flag=0}
  ' "$f" > "$f.on.tmp" || true

  {
    if grep -q '^on:' "$f.on.tmp" 2>/dev/null; then
      sed -n '2,$p' "$f.on.tmp"
    else
      cat <<'TRIG'
on:
  workflow_dispatch:
TRIG
    fi

    cat <<'JOBS'

jobs:
  blackduck_cli:
    runs-on: ubuntu-latest
    env:
      BLACKDUCK_URL: ${{ vars.BLACKDUCK_URL }}
      BLACKDUCK_TOKEN: ${{ secrets.BLACKDUCK_TOKEN }}
    steps:
      - uses: actions/checkout@v4

      - name: Download Bridge CLI (Thin Client)
        run: |
          set -euo pipefail
          mkdir -p .ci-tools
          # TODO: Download from your approved mirror and save as .ci-tools/bridge-cli
          # Example (placeholder):
          # curl -fL "<APPROVED_URL>/bridge-cli-linux-x64" -o .ci-tools/bridge-cli
          # chmod +x .ci-tools/bridge-cli

      - name: Run Bridge CLI (Black Duck SCA)
        run: |
          set -euo pipefail
          export BRIDGE_BLACKDUCKSCA_TOKEN="${BLACKDUCK_TOKEN}"
          ./.ci-tools/bridge-cli --stage blackducksca \
            blackducksca.url="${BLACKDUCK_URL}"
          # Optional quality gate example:
          # ./.ci-tools/bridge-cli --stage blackducksca \
          #   blackducksca.url="${BLACKDUCK_URL}" \
          #   blackducksca.scan.failure.severities=CRITICAL,HIGH
JOBS
  } | awk 'NR==1{print "name: Black Duck SCA - CLI"}1' > "$f.new"

  mv "$f.new" "$f"
  rm -f "$f.on.tmp"
  changed=true
}

# --- scan and migrate ---
shopt -s nullglob
found_any=false
for f in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  found_any=true
  if grep -qE 'uses:\s*synopsys-sig/synopsys-action@' "$f"; then
    migrate_plugin "$f"
  elif grep -q -- "--stage polaris" "$f"; then
    migrate_cli "$f"
  else
    msg "No Polaris patterns found in: $f (skipping)"
  fi
done
shopt -u nullglob

$found_any || die "No workflow files found under $WORKFLOWS_DIR"

# --- ensure git identity locally (only if missing) ---
if [[ -z "$(git -C "$REPO_DIR" config user.name || true)" ]]; then
  msg "Configuring local git user.name"
  git -C "$REPO_DIR" config user.name "ADO Migration Bot"
fi
if [[ -z "$(git -C "$REPO_DIR" config user.email || true)" ]]; then
  msg "Configuring local git user.email"
  git -C "$REPO_DIR" config user.email "ado-bot@your-company.com"
fi

# --- robust commit & push ---
if $changed && [[ "${AUTO_COMMIT}" == "true" ]]; then
  msg "Committing changes"

  # Stage only existing/changed workflow files safely
  git -C "$REPO_DIR" add --update .github/workflows || true

  (
    shopt -s nullglob
    wf_list=( "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml )
    if (( ${#wf_list[@]} )); then
      git -C "$REPO_DIR" add "${wf_list[@]}" || true
    fi
  )

  if ! git -C "$REPO_DIR" diff --cached --quiet; then
    git -C "$REPO_DIR" commit -m "$COMMIT_MESSAGE"
    if [[ -n "$COMMIT_BRANCH" ]]; then
      git -C "$REPO_DIR" push -u origin "$COMMIT_BRANCH"
    else
      git -C "$REPO_DIR" push
    fi
  else
    msg "No staged changes to commit"
  fi
else
  msg "No changes or AUTO_COMMIT=false, skipping commit"
fi

msg "Migration complete"
