#!/opt/homebrew/bin/bash
set -euo pipefail

# ===== CONFIG (override via env or flags) =====
USER_GH="${USER_GH:-}"            # Your GitHub username; auto-detected from 'gh' if empty
PROTOCOL="${PROTOCOL:-ssh}"       # ssh | https
EXECUTE="${EXECUTE:-0}"           # 0 = dry-run, 1 = apply changes
ADD_UPSTREAM="${ADD_UPSTREAM:-0}" # 1=keep/add upstream to original repo, 0=remove
ROOT="."                          # default scan root (overridden by positional arg)
# =============================================

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [ROOT]

Options:
  --execute             Apply changes (default is dry-run)
  --dry-run             Dry-run only (default)
  --https               Use HTTPS remotes (default: SSH)
  --ssh                 Use SSH remotes (default)
  --user USERNAME       Override GitHub username (else auto-detect via 'gh')
  --add-upstream        Keep/add an 'upstream' remote to original repo
  --no-upstream         Remove 'upstream' remote (default)
  --ignore TOKEN        Skip repos whose path or name contains TOKEN (repeatable)
  -h, --help            Show this help
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }

IGNORES=()

parse_args() {
  local positional_seen=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --execute) EXECUTE=1; shift ;;
      --dry-run) EXECUTE=0; shift ;;
      --https) PROTOCOL="https"; shift ;;
      --ssh) PROTOCOL="ssh"; shift ;;
      --user) USER_GH="${2:-}"; shift 2 ;;
      --add-upstream) ADD_UPSTREAM=1; shift ;;
      --no-upstream) ADD_UPSTREAM=0; shift ;;
      --ignore)
        if [[ -n "${2:-}" ]]; then IGNORES+=("$2"); fi
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*)
        echo "Unknown option: $1"; usage; exit 1 ;;
      *)
        if [[ $positional_seen -eq 0 ]]; then ROOT="$1"; positional_seen=1; shift
        else IGNORES+=("$1"); shift
        fi
        ;;
    esac
  done
}

gh_url() {
  local owner="$1" repo="$2"
  if [[ "$PROTOCOL" == "ssh" ]]; then
    printf 'git@github.com:%s/%s.git' "$owner" "$repo"
  else
    printf 'https://github.com/%s/%s.git' "$owner" "$repo"
  fi
}

parse_owner_repo() {
  local url="$1"
  url="${url%.git}"
  if [[ "$url" =~ ^git@github\.com:(.+)/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; return
  fi
  if [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"; return
  fi
  echo ""
}

ensure_user() {
  if [[ -z "$USER_GH" ]]; then
    USER_GH="$(gh api user -q .login 2>/dev/null || true)"
    [[ -n "$USER_GH" ]] || { echo "Could not determine GitHub username; set --user or USER_GH=..."; exit 1; }
  fi
}

matches_ignore() {
  local repo_dir="$1"
  local name; name="$(basename "$repo_dir")"
  for tok in "${IGNORES[@]:-}"; do
    [[ -z "$tok" ]] && continue
    if [[ "$repo_dir" == *"$tok"* || "$name" == *"$tok"* ]]; then
      return 0
    fi
  done
  return 1
}

process_repo() {
  local repo_dir="$1"

  if matches_ignore "$repo_dir"; then
    echo ">> skipped (ignored): $repo_dir"
    return 0
  fi

  if [[ ! -d "$repo_dir" ]]; then
    echo "!! not a dir: $repo_dir"
    return 0
  fi
  if [[ ! -d "$repo_dir/.git" && ! -f "$repo_dir/.git" ]]; then
    echo ">> skipped (no .git): $repo_dir"
    return 0
  fi

  echo "==> $repo_dir"

  local origin_url
  origin_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$origin_url" ]]; then
    echo "   - skipped: no 'origin' remote configured"
    echo
    return 0
  fi
  if [[ "$origin_url" != *github.com* ]]; then
    echo "   - skipped: non-GitHub origin: $origin_url"
    echo
    return 0
  fi

  local pair owner repo
  pair="$(parse_owner_repo "$origin_url")"
  if [[ -z "$pair" ]]; then
    echo "   - skipped: could not parse owner/repo from: $origin_url"
    echo
    return 0
  fi
  owner="${pair%/*}"
  repo="${pair#*/}"

  # Case-insensitive compare for your username
  shopt -s nocasematch
  if [[ "$owner" == "$USER_GH" ]]; then
    shopt -u nocasematch
    local desired_origin; desired_origin="$(gh_url "$USER_GH" "$repo")"
    if [[ "$origin_url" == "$desired_origin" ]]; then
      echo "   - origin already your repo ($desired_origin)"
    else
      echo "   - normalize origin -> $desired_origin"
      [[ "$EXECUTE" -eq 1 ]] && git -C "$repo_dir" remote set-url origin "$desired_origin"
    fi
    if git -C "$repo_dir" remote | grep -qx upstream; then
      if [[ "$ADD_UPSTREAM" -eq 0 ]]; then
        echo "   - removing upstream (per --no-upstream)"
        [[ "$EXECUTE" -eq 1 ]] && git -C "$repo_dir" remote remove upstream
      fi
    fi
    echo
    return 0
  fi
  shopt -u nocasematch

  echo "   - origin belongs to $owner/$repo"

  # Ensure your fork exists (no-op if it does)
  if gh repo view "$USER_GH/$repo" >/dev/null 2>&1; then
    echo "   - fork exists: $USER_GH/$repo"
  else
    echo "   - creating fork: $USER_GH/$repo (from $owner/$repo)"
    [[ "$EXECUTE" -eq 1 ]] && gh repo fork "$owner/$repo" --clone=false --remote=false >/dev/null
  fi

  local desired_origin desired_upstream
  desired_origin="$(gh_url "$USER_GH" "$repo")"
  desired_upstream="$(gh_url "$owner" "$repo")"

  echo "   - set origin -> $desired_origin"
  [[ "$EXECUTE" -eq 1 ]] && git -C "$repo_dir" remote set-url origin "$desired_origin"

  if [[ "$ADD_UPSTREAM" -eq 1 ]]; then
    if git -C "$repo_dir" remote | grep -qx upstream; then
      echo "   - set upstream -> $desired_upstream"
      [[ "$EXECUTE" -eq 1 ]] && git -C "$repo_dir" remote set-url upstream "$desired_upstream"
    else
      echo "   - add upstream -> $desired_upstream"
      [[ "$EXECUTE" -eq 1 ]] && git -C "$repo_dir" remote add upstream "$desired_upstream"
    fi
  else
    if git -C "$repo_dir" remote | grep -qx upstream; then
      echo "   - removing upstream (per --no-upstream)"
      [[ "$EXECUTE" -eq 1 ]] && git -C "$repo_dir" remote remove upstream
    fi
  fi

  echo
}

main() {
  need git
  need gh
  parse_args "$@"

  if [[ -z "$USER_GH" ]]; then
    USER_GH="$(gh api user -q .login 2>/dev/null || true)"
    [[ -n "$USER_GH" ]] || { echo "Could not determine GitHub username; set --user or USER_GH=..."; exit 1; }
  fi

  local abs_root
  abs_root="$(cd "$ROOT" && pwd)"
  echo "Scanning: $abs_root   as user: $USER_GH   protocol: $PROTOCOL   execute: $EXECUTE   add_upstream: $ADD_UPSTREAM"
  echo "Ignore tokens: ${IGNORES[*]:-<none>}"

  # Collect .git paths first (works for .git dir OR file)
  mapfile -t gitpaths < <(find "$abs_root" -name .git -print 2>/dev/null || true)

  if [[ ${#gitpaths[@]} -eq 0 ]]; then
    echo "No repos found under $abs_root"
    exit 0
  fi

  for gitpath in "${gitpaths[@]}"; do
    repo_dir="$(dirname "$gitpath")"
    process_repo "$repo_dir"
  done
}

main "$@"