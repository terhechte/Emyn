#!/usr/bin/env bash
set -euo pipefail

TARGET_PATH="platform-macos/swift/PlatformMacOSKit/platform_macosFFI.xcframework"
TARGET_PATH="${TARGET_PATH%/}"
FILTER_PATH="$TARGET_PATH/"
GITIGNORE_ENTRY="/$FILTER_PATH"
KEEP_LOCAL_COPY=1
FETCH_ALL=0
YES=0

usage() {
  cat <<'USAGE'
Usage: platform-macos/scripts/remove-xcframework-from-history.sh [options]

Rewrites local git history to remove:
  platform-macos/swift/PlatformMacOSKit/platform_macosFFI.xcframework

Options:
  -y, --yes       Run without the interactive confirmation prompt.
  --fetch-all     Fetch all remotes and tags before rewriting local refs.
  --no-restore    Do not restore a local untracked copy of the xcframework.
  -h, --help      Show this help.

After this script completes, review the result and force-push rewritten refs:
  git push --force-with-lease --all origin
  git push --force-with-lease --tags origin
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    -y|--yes)
      YES=1
      ;;
    --fetch-all)
      FETCH_ALL=1
      ;;
    --no-restore)
      KEEP_LOCAL_COPY=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
  shift
done

command -v git >/dev/null 2>&1 || die "git is required"

if git filter-repo -h >/dev/null 2>&1; then
  FILTER_REPO=(git filter-repo)
elif command -v git-filter-repo >/dev/null 2>&1; then
  FILTER_REPO=(git-filter-repo)
else
  cat >&2 <<'EOF'
error: git-filter-repo is required.

Install it with one of:
  brew install git-filter-repo
  python3 -m pip install --user git-filter-repo
EOF
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this from inside the repository"
cd "$REPO_ROOT"

if ! git diff --quiet --ignore-submodules --; then
  die "tracked working tree changes exist; commit or stash them before rewriting history"
fi

if ! git diff --cached --quiet --ignore-submodules --; then
  die "staged changes exist; commit or stash them before rewriting history"
fi

cat <<EOF
This will rewrite local git history for all local refs and remove:
  $TARGET_PATH

The script will not push anything. After it completes, you must force-push
the rewritten refs to update GitHub.
EOF

if ((YES == 0)); then
  [[ -t 0 ]] || die "non-interactive shell; pass --yes to run"
  read -r -p "Type REMOVE to continue: " confirmation
  [[ "$confirmation" == "REMOVE" ]] || die "aborted"
fi

if ((FETCH_ALL == 1)); then
  git fetch --all --tags --prune
fi

BACKUP_DIR=""
cleanup() {
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    rm -rf "$BACKUP_DIR"
  fi
}
trap cleanup EXIT

if ((KEEP_LOCAL_COPY == 1)) && [[ -e "$TARGET_PATH" ]]; then
  BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/emyn-xcframework-history-cleanup.XXXXXX")"
  cp -R "$TARGET_PATH" "$BACKUP_DIR/"
fi

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
ORIGIN_PUSH_URL="$(git remote get-url --push origin 2>/dev/null || true)"

"${FILTER_REPO[@]}" --force --invert-paths --path "$FILTER_PATH"

if [[ -n "$ORIGIN_URL" ]] && ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "$ORIGIN_URL"
  if [[ -n "$ORIGIN_PUSH_URL" && "$ORIGIN_PUSH_URL" != "$ORIGIN_URL" ]]; then
    git remote set-url --push origin "$ORIGIN_PUSH_URL"
  fi
fi

if [[ ! -f .gitignore ]]; then
  : >.gitignore
fi

if ! grep -Fxq -- "$GITIGNORE_ENTRY" .gitignore; then
  {
    printf '\n# Generated PlatformMacOSKit binary artifact\n'
    printf '%s\n' "$GITIGNORE_ENTRY"
  } >>.gitignore
fi

if [[ -n "$BACKUP_DIR" && -e "$BACKUP_DIR/$(basename "$TARGET_PATH")" ]]; then
  mkdir -p "$(dirname "$TARGET_PATH")"
  rm -rf "$TARGET_PATH"
  cp -R "$BACKUP_DIR/$(basename "$TARGET_PATH")" "$(dirname "$TARGET_PATH")/"
  echo "Restored local ignored copy: $TARGET_PATH"
fi

if git ls-files -- "$TARGET_PATH" | grep -q .; then
  die "$TARGET_PATH is still tracked after filtering"
fi

if git log --all --format='%H' -- "$TARGET_PATH" | grep -q .; then
  die "$TARGET_PATH still appears in rewritten history"
fi

cat <<EOF
Done. The xcframework path is no longer tracked or present in local history.

Review:
  git status --short

Push rewritten history when ready:
  git push --force-with-lease --all origin
  git push --force-with-lease --tags origin

Anyone with an existing clone will need to rebase carefully or reclone after
the force-push.
EOF
