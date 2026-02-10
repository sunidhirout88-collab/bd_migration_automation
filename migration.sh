#!/usr/bin/env bash
set -Eeuo pipefail
trap 'code=$?; echo "migration.sh ERROR line ${LINENO}: ${BASH_COMMAND} -> $code"; exit $code' ERR

# Uncomment for verbose tracing:
#set -x

REPO_DIR="${1:-}"
[[ -n "$REPO_DIR" ]] || { echo "Usage: $0 <repo_dir>"; exit 2; }
[[ -d "$REPO_DIR/.git" ]] || { echo "Not a git repo: $REPO_DIR"; exit 2; }

cd "$REPO_DIR"

# --- Configurable Jenkins credential IDs ---
BD_URL_CRED_ID="${BD_URL_CRED_ID:-blackduck-url}"
BD_TOKEN_CRED_ID="${BD_TOKEN_CRED_ID:-blackduck-api-token}"

STAGE_DL_BRIDGE_NAME='Download Bridge CLI'
STAGE_BD_NAME='Black Duck via Bridge CLI'
STAGE_CHECKOUT_NAME='Checkout'

TEMPLATE_STAGE_DOWNLOAD_BRIDGE="$(cat <<'EOF'
    stage('Download Bridge CLI') {
      steps {
        sh '''
          set -euo pipefail
          mkdir -p .ci-tools
          # TODO: Replace with your actual download (curl/wget/artifactory)
          # Example:
          #   curl -sSL -o .ci-tools/bridge "<YOUR_BRIDGE_CLI_URL>"
          #   chmod +x .ci-tools/bridge
          # Placeholder:
          if [ ! -x .ci-tools/bridge ]; then
            printf '#!/usr/bin/env bash\necho "Bridge CLI placeholder. Replace with real download."\n' > .ci-tools/bridge
            chmod +x .ci-tools/bridge
          fi
        '''
      }
    }
EOF
)"

TEMPLATE_STAGE_BLACKDUCK="$(cat <<'EOF'
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
)"

backup_file() {
  local f="$1"; local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  cp -p -- "$f" "${f}.bak.${ts}"
  echo "    Backup: ${f}.bak.${ts}"
}

remove_polaris_stages() {
  local file="$1" tmp="${file}.tmp.$$"
  awk '
    BEGIN { skipping=0; level=0 }
    {
      line=$0
      if (!skipping) {
        if (match(line, /stage[[:space:]]*\([[:space:]]*'\''[^'\'']*Polaris[^'\'']*'\''[[:space:]]*\)/)) {
          skipping=1
          openC = gsub(/\{/,"{",line)
          closeC = gsub(/\}/,"}",line)
          level += openC - closeC
          next
        } else {
          print line
          next
        }
      } else {
        openC = gsub(/\{/,"{",line)
        closeC = gsub(/\}/,"}",line)
        level += openC - closeC
        if (level <= 0) { skipping=0; level=0 }
        next
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

ensure_env_bd_credentials() {
  local file="$1" tmp="${file}.tmp.$$"
  awk -v bd_url_id="$BD_URL_CRED_ID" -v bd_token_id="$BD_TOKEN_CRED_ID" '
    BEGIN { in_env=0; bd_url_present=0; bd_token_present=0; env_indent="" }
    {
      line=$0
      if (!in_env) {
        if (match(line, /^[ \t]*environment[ \t]*\{/)) {
          in_env=1
          match(line, /^([ \t]*)environment[ \t]*\{/, m); env_indent=m[1]
          print line; next
        } else { print line; next }
      } else {
        if (match(line, /^[ \t]*\}/)) {
          if (!bd_url_present)   print env_indent "  BLACKDUCK_URL = credentials(\x27" bd_url_id "\x27)"
          if (!bd_token_present) print env_indent "  BLACKDUCK_API_TOKEN = credentials(\x27" bd_token_id "\x27)"
          print line; in_env=0; next
        }
        if (line ~ /POLARIS_SERVER_URL[ \t]*=/ || line ~ /POLARIS_ACCESS_TOKEN[ \t]*=/) { next }
        if (line ~ /BLACKDUCK_URL[ \t]*=/) { bd_url_present=1 }
        if (line ~ /BLACKDUCK_API_TOKEN[ \t]*=/) { bd_token_present=1 }
        print line; next
      }
    }
    END {
      # If file had no environment block at all, append one
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

has_stage() {
  local file="$1" stage_name="$2"
  grep -q "stage('${stage_name}')" "$file"
}

insert_after_stage() {
  local file="$1" anchor_stage="$2" insert_block="$3" tmp="${file}.tmp.$$"
  awk -v anchor="$anchor_stage" -v add="$insert_block" '
    BEGIN { in_target=0; level=0; printed_add=0 }
    {
      line=$0
      print line
      if (printed_add) next
      if (line ~ "stage(\x27" anchor "\x27)") { in_target=1 }
      if (in_target) {
        openC = gsub(/\{/,"{",line)
        closeC = gsub(/\}/,"}",line)
        level += openC - closeC
        if (level <= 0) { print add; printed_add=1; in_target=0; level=0 }
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

ensure_download_before_bd() {
  local file="$1" tmp="${file}.tmp.$$"
  has_stage "$file" "$STAGE_BD_NAME" || return 0
  has_stage "$file" "$STAGE_DL_BRIDGE_NAME" && return 0
  awk -v bd="stage(\x27'"$STAGE_BD_NAME"'\x27)" -v dlblk="$TEMPLATE_STAGE_DOWNLOAD_BRIDGE" '
    { line=$0; if (line ~ bd) { print dlblk } ; print line }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Discover Jenkinsfiles
mapfile -t jfiles < <(find . -type f \( -iname 'Jenkinsfile' -o -iname 'jenkinsfile' \) -not -path '*/.git/*' | sort)
echo "Jenkinsfiles found: ${#jfiles[@]}"
for jf in "${jfiles[@]}"; do echo "  -> $jf"; done

for jf in "${jfiles[@]}"; do
  echo "Processing $jf"
  backup_file "$jf"
  remove_polaris_stages "$jf"
  ensure_env_bd_credentials "$jf"
  if ! has_stage "$jf" "$STAGE_BD_NAME"; then
    combined_block=$(printf "%s\n%s\n" "$TEMPLATE_STAGE_DOWNLOAD_BRIDGE" "$TEMPLATE_STAGE_BLACKDUCK")
    if has_stage "$jf" "$STAGE_CHECKOUT_NAME"; then
      insert_after_stage "$jf" "$STAGE_CHECKOUT_NAME" "$combined_block"
    else
      printf "\n%s\n%s\n" "$TEMPLATE_STAGE_DOWNLOAD_BRIDGE" "$TEMPLATE_STAGE_BLACKDUCK" >> "$jf"
    fi
  fi
  ensure_download_before_bd "$jf"
  echo "Done $jf"
done
