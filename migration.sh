#!/usr/bin/env bash
set -Eeuo pipefail
trap 'code=$?; echo "migration.sh ERROR line ${LINENO}: ${BASH_COMMAND} -> $code"; exit $code' ERR
# set -x  # uncomment for verbose tracing

REPO_DIR="${1:-}"
[[ -n "$REPO_DIR" ]] || { echo "Usage: $0 <repo_dir>"; exit 2; }
[[ -d "$REPO_DIR/.git" ]] || { echo "Not a git repo: $REPO_DIR"; exit 2; }
cd "$REPO_DIR"

# --- Configurable Jenkins credential IDs (override via env if needed) ---
BD_URL_CRED_ID="${BD_URL_CRED_ID:-blackduck-url}"
BD_TOKEN_CRED_ID="${BD_TOKEN_CRED_ID:-blackduck-api-token}"

STAGE_DL_BRIDGE_NAME='Download Bridge CLI'
STAGE_BD_NAME='Black Duck via Bridge CLI'
STAGE_CHECKOUT_NAME='Checkout'

# ---- Stage templates built with printf (no heredocs) ----
TEMPLATE_STAGE_DOWNLOAD_BRIDGE="$(
  printf "%s\n" \
"    stage('Download Bridge CLI') {" \
"      steps {" \
"        sh '''" \
"          set -euo pipefail" \
"          mkdir -p .ci-tools" \
"          # TODO: Replace with your actual download (curl/wget/artifactory)" \
"          # Example:" \
"          #   curl -sSL -o .ci-tools/bridge \"<YOUR_BRIDGE_CLI_URL>\"" \
"          #   chmod +x .ci-tools/bridge" \
"          # Placeholder:" \
"          if [ ! -x .ci-tools/bridge ]; then" \
"            printf '#!/usr/bin/env bash\necho \"Bridge CLI placeholder. Replace with real download.\"\n' > .ci-tools/bridge" \
"            chmod +x .ci-tools/bridge" \
"          fi" \
"        '''" \
"      }" \
"    }"
)"

TEMPLATE_STAGE_BLACKDUCK="$(
  printf "%s\n" \
"    stage('Black Duck via Bridge CLI') {" \
"      steps {" \
"        sh '''" \
"          set -euo pipefail" \
"          test -x .ci-tools/bridge" \
"          # Ensure bridge.yml has a \"blackduck\" stage configured" \
"          .ci-tools/bridge --stage blackduck --input bridge.yml" \
"        '''" \
"      }" \
"    }"
)"

backup_file() {
  local f="$1"
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  cp -p -- "$f" "${f}.bak.${ts}"
  echo "    Backup: ${f}.bak.${ts}"
}

# Remove any stage whose title contains 'Polaris'
remove_polaris_stages() {
  local file="$1"
  local tmp="${file}.tmp.$$"
  awk '
    BEGIN { skipping=0; level=0; found_open=0 }
    {
      line=$0
      if (!skipping) {
        if (line ~ /stage[[:space:]]*\([[:space:]]*\047[^\047]*Polaris[^\047]*\047[[:space:]]*\)/) {
          skipping=1; level=0; found_open=0
          # fall through to count braces on this same line
        } else {
          print line
          next
        }
      }
      # Skipping block: count braces until the stage block closes
      openC = gsub(/\{/, "&", line)
      closeC = gsub(/\}/, "&", line)
      if (!found_open) {
        if (openC > 0) {
          level += openC - closeC
          found_open=1
        }
        if (!found_open) next
      } else {
        level += openC - closeC
      }
      if (level <= 0) {
        # Completed the block; stop skipping
        skipping=0; level=0; found_open=0
      }
      next
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Ensure environment block contains Black Duck creds; remove Polaris env lines
ensure_env_bd_credentials() {
  local file="$1"
  local tmp="${file}.tmp.$$"
  awk -v bd_url_id="$BD_URL_CRED_ID" -v bd_token_id="$BD_TOKEN_CRED_ID" '
    BEGIN { in_env=0; saw_env=0; bd_url_present=0; bd_token_present=0; env_indent="" }
    {
      line=$0
      if (!in_env) {
        # Start of environment block?
        if (match(line, /^[ \t]*environment[ \t]*\{/)) {
          in_env=1; saw_env=1
          match(line, /^([ \t]*)environment[ \t]*\{/, m)
          env_indent=m[1]
          bd_url_present=0; bd_token_present=0
          print line
          next
        } else {
          print line
          next
        }
      } else {
        # Inside environment block
        # Closing the environment block?
        if (match(line, /^[ \t]*\}/)) {
          if (!bd_url_present)   print env_indent "  BLACKDUCK_URL = credentials(\x27" bd_url_id "\x27)"
          if (!bd_token_present) print env_indent "  BLACKDUCK_API_TOKEN = credentials(\x27" bd_token_id "\x27)"
          print line
          in_env=0
          next
        }
        # Drop any Polaris lines
        if (line ~ /POLARIS_SERVER_URL[ \t]*=/ || line ~ /POLARIS_ACCESS_TOKEN[ \t]*=/) {
          next
        }
        # Track if BD lines already exist
        if (line ~ /BLACKDUCK_URL[ \t]*=/)       bd_url_present=1
        if (line ~ /BLACKDUCK_API_TOKEN[ \t]*=/) bd_token_present=1

        print line
        next
      }
    }
    END {
      # If no environment block at all, append one
      if (!saw_env) {
        print ""
        print "  environment {"
        print "    BLACKDUCK_URL = credentials(\x27" bd_url_id "\x27)"
        print "    BLACKDUCK_API_TOKEN = credentials(\x27" bd_token_id "\x27)"
        print "  }"
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Check if a stage with exact name exists
has_stage() {
  local file="$1"
  local stage_name="$2"
  grep -Fq "stage('${stage_name}')" "$file"
}

# Insert a block immediately AFTER the end of the given stage block
insert_after_stage() {
  local file="$1"
  local anchor_stage="$2"
  local insert_block="$3"
  local tmp="${file}.tmp.$$"
  awk -v anchor="$anchor_stage" -v add="$insert_block" '
    BEGIN { in_target=0; level=0; found_open=0; inserted=0 }
    {
      line=$0
      print line
      if (inserted) next

      if (!in_target) {
        if (line ~ "stage\\(\x27" anchor "\x27\\)") {
          in_target=1; level=0; found_open=0
        } else {
          next
        }
      }

      # Count braces after we found the anchor stage
      openC = gsub(/\{/, "&", line)
      closeC = gsub(/\}/, "&", line)
      if (!found_open) {
        if (openC > 0) {
          level += openC - closeC
          found_open=1
        }
        if (!found_open) next
      } else {
        level += openC - closeC
      }

      if (level <= 0) {
        print add
        inserted=1
        in_target=0; level=0; found_open=0
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# If BD stage exists but Download stage does not, insert Download right before BD
ensure_download_before_bd() {
  local file="$1"
  local tmp="${file}.tmp.$$"
  has_stage "$file" "$STAGE_BD_NAME" || return 0
  has_stage "$file" "$STAGE_DL_BRIDGE_NAME" && return 0
  awk -v bd="stage\\(\x27'"$STAGE_BD_NAME"'\\x27\\)" -v dlblk="$TEMPLATE_STAGE_DOWNLOAD_BRIDGE" '
    {
      line=$0
      if (line ~ bd) {
        print dlblk
      }
      print line
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ---- Discover and process Jenkinsfiles ----
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
      # If no Checkout stage, append both at the end
      printf "\n%s\n%s\n" "$TEMPLATE_STAGE_DOWNLOAD_BRIDGE" "$TEMPLATE_STAGE_BLACKDUCK" >> "$jf"
    fi
  fi

  ensure_download_before_bd "$jf"
  echo "Done $jf"
done
# ---- Commit & push changes (in target repo) ----
current_branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD || true)"
target_branch="${TARGET_BRANCH:-$current_branch}"

if [ "$current_branch" = "HEAD" ] && [ -n "${target_branch:-}" ]; then
  git -C "$REPO_DIR" checkout -B "$target_branch"
fi

git -C "$REPO_DIR" config --global --add safe.directory "$REPO_DIR"
git -C "$REPO_DIR" status --porcelain

if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
  git -C "$REPO_DIR" config user.name  "${COMMIT_AUTHOR_NAME:-azure-pipelines-bot}"
  git -C "$REPO_DIR" config user.email "${COMMIT_AUTHOR_EMAIL:-azure-pipelines-bot@users.noreply.github.com}"

  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -m "Migrate Polaris → Black Duck (Bridge CLI) [automated]"

  orig_url="$(git -C "$REPO_DIR" remote get-url origin || echo)"
  set +x
  if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$orig_url" ]; then
    case "$orig_url" in
      https://github.com/*)
        push_url="${orig_url/https:\/\//https:\/\/x-access-token:${GITHUB_TOKEN}@}"
        ;;
      git@github.com:*)
        repo_path="$(printf "%s" "$orig_url" | sed -E 's#git@github.com:(.*)#\1#')"
        push_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${repo_path}"
        ;;
      *)
        push_url="$orig_url"
        ;;
    esac
    git -C "$REPO_DIR" remote set-url --push origin "$push_url"
  fi
  set -x

  git -C "$REPO_DIR" push origin "HEAD:${target_branch}"

  set +x
  [ -n "$orig_url" ] && git -C "$REPO_DIR" remote set-url --push origin "$orig_url" || true
  set -x

  echo "Pushed changes to ${target_branch} in target repo."
else
  echo "No changes to commit in target repo."
fi

# ---- Commit & push changes (optional) ----
# Uses env:
#   TARGET_BRANCH (preferred branch to push)
#   GITHUB_TOKEN  (GitHub token with contents:write)
#   COMMIT_AUTHOR_NAME / COMMIT_AUTHOR_EMAIL (optional overrides)

#current_branch="$(git rev-parse --abbrev-ref HEAD || true)"
#target_branch="${TARGET_BRANCH:-$current_branch}"

# If detached, create/switch to target branch
#if [ "$current_branch" = "HEAD" ] && [ -n "${target_branch:-}" ]; then
 # git checkout -B "$target_branch"
#fi

# Show what changed
#git status --porcelain

#if [ -n "$(git status --porcelain)" ]; then
 # git config user.name  "${COMMIT_AUTHOR_NAME:-azure-pipelines-bot}"
  #git config user.email "${COMMIT_AUTHOR_EMAIL:-azure-pipelines-bot@users.noreply.github.com}"

  #git add -A
  #git commit -m "Migrate Polaris → Black Duck (Bridge CLI) [automated]"

  # Prepare push URL with token (hide token from logs)
  #orig_url="$(git remote get-url origin || echo)"
  #set +x
  #if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$orig_url" ]; then
   # case "$orig_url" in
    #  https://github.com/*)
     #   push_url="${orig_url/https:\/\//https:\/\/x-access-token:${GITHUB_TOKEN}@}"
      #  ;;
      #git@github.com:*)
        # convert SSH remote to HTTPS with token
       # repo_path="$(printf "%s" "$orig_url" | sed -E 's#git@github.com:(.*)#\1#')"
        #push_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${repo_path}"
        #;;
      #*)
       # push_url="$orig_url"
        #;;
    #esac
    #git remote set-url --push origin "$push_url"
  #fi
  #set -x

  # Push to target branch
  #git push origin "HEAD:${target_branch}"

  # Restore original (non-sensitive) push URL
  #set +x
  #[ -n "$orig_url" ] && git remote set-url --push origin "$orig_url" || true
  #set -x

  #echo "Pushed changes to ${target_branch}"
#else
  #echo "No changes to commit."
#fi
