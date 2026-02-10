#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# repo_migrate_polaris_to_blackduck.sh
#
# Scans the current (or git) repo for Jenkinsfiles and:
#  - Removes "Polaris" stages
#  - Inserts "Download Bridge CLI" and "Black Duck via Bridge CLI" stages
#  - Updates environment block: removes POLARIS_*; ensures BLACKDUCK_* credentials
#
# Safe to run multiple times; creates timestamped backups.
#
# Usage:
#   bash repo_migrate_polaris_to_blackduck.sh
#
# Optional flags:
#   --dry-run   : Show which files would change; do not modify files.
#   --root PATH : Treat PATH as repo root (default: auto git root or current dir)
# ------------------------------------------------------------------------------

# ===== Configurable: Credential IDs used in Jenkins ============================
BD_URL_CRED_ID="blackduck-url"
BD_TOKEN_CRED_ID="blackduck-api-token"

# ===== Stage names (do not include regex here to avoid escaping surprises) =====
STAGE_DL_BRIDGE_NAME='Download Bridge CLI'
STAGE_BD_NAME='Black Duck via Bridge CLI'
STAGE_CHECKOUT_NAME='Checkout'

# ===== Stage Templates =========================================================
read -r -d '' TEMPLATE_STAGE_DOWNLOAD_BRIDGE <<'EOF'
    stage('Download Bridge CLI') {
      steps {
        sh '''
          set -euo pipefail
          mkdir -p .ci-tools
          # TODO: Replace with your actual download (curl/wget/artifactory)
          # Example:
          #   curl -sSL -o .ci-tools/bridge "<YOUR_BRIDGE_CLI_URL>"
          #   chmod +x .ci-tools/bridge
          # Placeholder to avoid failures if not yet wired:
          if [ ! -x .ci-tools/bridge ]; then
            printf '#!/usr/bin/env bash\necho "Bridge CLI placeholder. Replace with real download."\n' > .ci-tools/bridge
            chmod +x .ci-tools/bridge
          fi
        '''
      }
    }
EOF

read -r -d '' TEMPLATE_STAGE_BLACKDUCK <<'EOF'
    stage('Black Duck via Bridge CLI') {
      steps {
        sh '''
          set -euo pipefail
          test -x .ci-tools/bridge
          # Ensure bridge.yml has a "blackduck" stage configured
          .ci-tools/bridge --stage blackduck --input bridge.yml
        '''
      }
    }
EOF

# ===== CLI flags ===============================================================
DRY_RUN="false"
REPO_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    --root) REPO_ROOT="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ===== Resolve repo root =======================================================
if [[ -z "${REPO_ROOT}" ]]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
  else
    REPO_ROOT="$(pwd)"
  fi
fi
cd "$REPO_ROOT"

echo "Repo root: $REPO_ROOT"
[[ "$DRY_RUN" == "true" ]] && echo "[DRY-RUN] No files will be modified."

# ===== Helper: create timestamped backup ======================================
backup_file() {
  local f="$1"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  cp -p -- "$f" "${f}.bak.${ts}"
  echo "  Backup: ${f}.bak.${ts}"
}

# ===== Helper: remove Polaris stages by stage name match ======================
remove_polaris_stages() {
  local file="$1" tmp="${file}.tmp.$$"

  # We remove any stage whose title contains "Polaris" (case-sensitive by Jenkins convention)
  awk '
    function count(s, ch,   n){ n=gsub(ch,"",s); return n }
    BEGIN { skipping=0; level=0 }
    {
      line=$0
      if (!skipping) {
        # Detect stage header line with name containing Polaris
        if (match(line, /stage[[:space:]]*\([[:space:]]*'\''[^'\'']*Polaris[^'\'']*'\''[[:space:]]*\)/)) {
          # Start skipping from this line until the matching block closes
          skipping=1
          # If this line contains any { or } adjust level now
          openC = gsub(/\{/,"{",line)
          closeC = gsub(/\}/,"}",line)
          level += openC - closeC
          next
        } else {
          print line
          # If this non-stage line includes braces, keep overall balance (not necessary here)
          next
        }
      } else {
        # We are skipping a Polaris stage block
        openC = gsub(/\{/,"{",line)
        closeC = gsub(/\}/,"}",line)
        level += openC - closeC
        # End skipping when block level balances back to <=0 (we passed closing brace)
        if (level <= 0) {
          skipping=0
          level=0
        }
        next
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ===== Helper: Update environment block =======================================
# - Remove POLARIS_* lines
# - Ensure BLACKDUCK_URL and BLACKDUCK_API_TOKEN exist (with credential IDs)
ensure_env_bd_credentials() {
  local file="$1" tmp="${file}.tmp.$$"
  awk -v bd_url_id="$BD_URL_CRED_ID" -v bd_token_id="$BD_TOKEN_CRED_ID" '
    BEGIN {
      in_env=0
      bd_url_present=0
      bd_token_present=0
      env_indent=""
    }
    # Helper to trim leading spaces
    function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
    {
      line=$0

      if (!in_env) {
        # Detect start of environment block
        if (match(line, /^[ \t]*environment[ \t]*\{/)) {
          in_env=1
          # capture indentation (non-destructive)
          match(line, /^([ \t]*)environment[ \t]*\{/, m)
          env_indent=m[1]
          print line
          next
        } else {
          print line
          next
        }
      } else {
        # Inside environment block
        # Check for closing brace at this nesting level (approximate)
        if (match(line, /^[ \t]*\}/)) {
          # Before closing, ensure BD vars exist
          if (!bd_url_present) {
            print env_indent "  BLACKDUCK_URL = credentials(\x27" bd_url_id "\x27)"
          }
          if (!bd_token_present) {
            print env_indent "  BLACKDUCK_API_TOKEN = credentials(\x27" bd_token_id "\x27)"
          }
          print line
          in_env=0
          next
        }

        # Skip Polaris lines entirely
        if (line ~ /POLARIS_SERVER_URL[ \t]*=/ || line ~ /POLARIS_ACCESS_TOKEN[ \t]*=/) {
          # skip
          next
        }

        # Detect if BD lines already present
        if (line ~ /BLACKDUCK_URL[ \t]*=/)   { bd_url_present=1 }
        if (line ~ /BLACKDUCK_API_TOKEN[ \t]*=/) { bd_token_present=1 }

        print line
        next
      }
    }
    END {
      # If no environment block existed at all, create one at end
      if (!in_env && bd_url_present==0 && bd_token_present==0) {
        print ""
        print "  environment {"
        print "    BLACKDUCK_URL = credentials(\x27" bd_url_id "\x27)"
        print "    BLACKDUCK_API_TOKEN = credentials(\x27" bd_token_id "\x27)"
        print "  }"
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ===== Helper: Does a stage with exact name exist? ============================
has_stage() {
  local file="$1" stage_name="$2"
  grep -q "stage('${stage_name}')" "$file"
}

# ===== Helper: Insert stages after a specific stage block =====================
insert_after_stage() {
  local file="$1" anchor_stage="$2" insert_block="$3" tmp="${file}.tmp.$$"

  awk -v anchor="$anchor_stage" -v add="$insert_block" '
    BEGIN { in_target=0; level=0; printed_add=0 }
    {
      line=$0
      print line
      if (printed_add) next

      if (line ~ "stage(\x27" anchor "\x27)") {
        in_target=1
      }
      if (in_target) {
        # Track braces to find end of this stage block
        openC = gsub(/\{/,"{",line)
        closeC = gsub(/\}/,"}",line)
        level += openC - closeC
        if (level <= 0) {
          # End of block: insert our content
          print add
          printed_add=1
          in_target=0
          level=0
        }
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ===== Helper: Insert Download before Black Duck if missing ===================
ensure_download_before_bd() {
  local file="$1" tmp="${file}.tmp.$$"

  # Only if BD stage exists and Download stage does not
  has_stage "$file" "$STAGE_BD_NAME" || return 0
  has_stage "$file" "$STAGE_DL_BRIDGE_NAME" && return 0

  # Insert Download immediately before BD stage
  awk -v bd="stage(\x27'"$STAGE_BD_NAME"'\x27)" -v dlblk="$TEMPLATE_STAGE_DOWNLOAD_BRIDGE" '
    {
      line=$0
      if (line ~ bd) {
        print dlblk
      }
      print line
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ===== Discover Jenkinsfiles ===================================================
# Priority: tracked by git; then fallback to filesystem search
declare -a JFILES=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r f; do
    # Filter to Jenkinsfile-like paths
    if [[ "$(basename "$f")" =~ ^[Jj]enkinsfile$ ]]; then
      JFILES+=("$f")
    fi
  done < <(git ls-files)
fi

# Add untracked / general matches
while IFS= read -r f; do
  # Skip .git directories just in case
  [[ "$f" == *"/.git/"* ]] && continue
  JFILES+=("$f")
done < <(find . -type f \( -iname 'Jenkinsfile' -o -iname 'jenkinsfile' \) -not -path '*/.git/*')

# Deduplicate
if [[ "${#JFILES[@]}" -eq 0 ]]; then
  echo "No Jenkinsfiles found."
  exit 0
fi
mapfile -t JFILES < <(printf "%s\n" "${JFILES[@]}" | awk '!seen[$0]++' | sort)

echo "Found ${#JFILES[@]} Jenkinsfile(s):"
printf '  - %s\n' "${JFILES[@]}"

# ===== Process each Jenkinsfile ==============================================
for jf in "${JFILES[@]}"; do
  echo ""
  echo "Processing: $jf"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY-RUN] Would back up and modify $jf"
    continue
  fi

  backup_file "$jf"

  # 1) Remove all stages with "Polaris" in their name
  remove_polaris_stages "$jf"

  # 2) Ensure environment has Black Duck credentials and remove POLARIS_* entries
  ensure_env_bd_credentials "$jf"

  # 3) Decide insertion point:
  #    If Black Duck stage not present, insert Download + Black Duck after Checkout
  if ! has_stage "$jf" "$STAGE_BD_NAME"; then
    combined_block=$(printf "%s\n%s\n" "$TEMPLATE_STAGE_DOWNLOAD_BRIDGE" "$TEMPLATE_STAGE_BLACKDUCK")
    if has_stage "$jf" "$STAGE_CHECKOUT_NAME"; then
      insert_after_stage "$jf" "$STAGE_CHECKOUT_NAME" "$combined_block"
    else
      # If no Checkout stage, append at end of file safely
      printf "\n%s\n%s\n" "$TEMPLATE_STAGE_DOWNLOAD_BRIDGE" "$TEMPLATE_STAGE_BLACKDUCK" >> "$jf"
    fi
  fi

  # 4) If BD exists but Download does not, insert Download right before BD
  ensure_download_before_bd "$jf"

  echo "  Updated: $jf"
done

echo ""
echo "Done."
``
