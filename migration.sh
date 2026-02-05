# Commit & push only if changed
if git diff --quiet; then
  echo "No changes detected. Nothing to commit."
  exit 0
fi

git add "${PIPELINE_FILE}"
git commit -m "Migrate pipeline: Polaris -> Black Duck SCA server scan"

# --- Push using GitHub PAT securely ---
: "${GITHUB_PAT:?GITHUB_PAT is not set}"

# Prevent accidental secret printing
set +x
AUTH_HEADER=$(printf "x-access-token:%s" "$GITHUB_PAT" | base64 -w0)
set -x

git -c http.extraheader="AUTHORIZATION: basic ${AUTH_HEADER}" push origin "${BRANCH}"

echo "✅ Migration complete and pushed."
