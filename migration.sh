# ---- Commit & push changes (optional) ----
# Uses env:
#   TARGET_BRANCH (preferred branch to push)
#   GITHUB_TOKEN  (GitHub token with contents:write)
#   COMMIT_AUTHOR_NAME / COMMIT_AUTHOR_EMAIL (optional overrides)

current_branch="$(git rev-parse --abbrev-ref HEAD || true)"
target_branch="${TARGET_BRANCH:-$current_branch}"

# If detached, create/switch to target branch
if [ "$current_branch" = "HEAD" ] && [ -n "${target_branch:-}" ]; then
  git checkout -B "$target_branch"
fi

# Show what changed
git status --porcelain

if [ -n "$(git status --porcelain)" ]; then
  git config user.name  "${COMMIT_AUTHOR_NAME:-azure-pipelines-bot}"
  git config user.email "${COMMIT_AUTHOR_EMAIL:-azure-pipelines-bot@users.noreply.github.com}"

  git add -A
  git commit -m "Migrate Polaris → Black Duck (Bridge CLI) [automated]"

  # Prepare push URL with token (hide token from logs)
  orig_url="$(git remote get-url origin || echo)"
  set +x
  if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$orig_url" ]; then
    case "$orig_url" in
      https://github.com/*)
        push_url="${orig_url/https:\/\//https:\/\/x-access-token:${GITHUB_TOKEN}@}"
        ;;
      git@github.com:*)
        # convert SSH remote to HTTPS with token
        repo_path="$(printf "%s" "$orig_url" | sed -E 's#git@github.com:(.*)#\1#')"
        push_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${repo_path}"
        ;;
      *)
        push_url="$orig_url"
        ;;
    esac
    git remote set-url --push origin "$push_url"
  fi
  set -x

  # Push to target branch
  git push origin "HEAD:${target_branch}"

  # Restore original (non-sensitive) push URL
  set +x
  [ -n "$orig_url" ] && git remote set-url --push origin "$orig_url" || true
  set -x

  echo "Pushed changes to ${target_branch}"
else
  echo "No changes to commit."
fi
