#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG (override via env) =====
USER_GH="${USER_GH:-}"            # Your GitHub username; auto-detected from 'gh' if empty
PROTOCOL="${PROTOCOL:-ssh}"       # ssh | https
ROOT="."                          # default scan root (can be overridden by first non-flag arg)
EXECUTE="${EXECUTE:-0}"           # 0 = dry-run, 1 = apply changes
ADD_UPSTREAM="${ADD_UPSTREAM:-0}" # 1=keep/add upstream to original, 0=remove
MAXDEPTH="${MAXDEPTH:-4}"         # how deep to search for repos
# ====================================

IGNORES=()                        # tokens/paths to skip

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [ROOT] [--ignore repoA] [--ignore path/to/repoB] ...

Options:
  --execute             Apply changes (default is dry-run)
  --dry-run             Dry-run only (default)
  --https               Use HTTPS remotes (default: SSH)
  --ssh                 Use SSH remotes (default)
  --user USERNAME       Override GitHub username (else auto-detect via 'gh')
  --add-upstream        Keep/add an 'upstream' remote to original repo
  --no-upstream         Remove 'upstream' remote (default)
  --maxdepth N          Set find max depth (default: ${MAXDEPTH})
  --ignore TOKEN        Skip repos whose path or name matches TOKEN (can repeat)

Examples:
  $(basename "$0") ~/dev --ignore sandbox --ignore /full/path/to/special-repo
  USER_GH=virtualpaul EXECUTE=1 $(basename "$0") ~/dev --https --add-upstream --ignore experimental
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }

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
      --maxdepth) MAXDEPTH="${2:-4}"; shift 2 ;;
      --ignore) IGNORES+=("${2:-}"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*)
        echo "Unknown option: $1"; usage; exit 1 ;;
      *)
        if [[ $positional_seen -eq 0 ]]; then
          ROOT="$1"; positional_seen=1; shift
        else
          # Treat any additional bare words as ignores (nice shortcut)
          IGNORES+=("$1"); shift
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

is_ignored() {
  local repo_dir="$1"
  local name; name="$(basename "$repo_dir")"
  for tok in "${IGNORES[@]:-}"; do
    # substring match on either full path or repo name
    [[ "$repo_dir" == *"$tok"* || "$name" == *"$tok"* ]] && return 0
  done
  return 0
}

# Faster exact/substring ignore (case-sensitive); tweak if you need regex/glob semantics
matches_ignore() {
  local repo_dir="$1"
  local name; name="$(basename "$repo_dir")"
  for tok in "${IGNORES[@]:-}"; do
    [[ "$repo_dir" == *"$tok"* || "$name" == *"$tok"* ]] && return 0
  done
  return 1
}

fork_exists() { gh repo view "$USER_GH/$1" >/dev/null 2>&1; }

create_fork_if_missing() {
  local src_owner="$1" src_repo="$2"
  if fork_exists "$src_repo"; then
    echo "   - fork already exists: $USER_GH/$src_repo"
  else
    echo "   - creating fork: $USER_GH/$src_repo (from $src_owner/$src_repo)"
    [[ "$EXECUTE" -eq 1 ]] && gh repo fork "$src_owner/$src_repo" --clone=false --remote=false >/dev/null
  fi
}

process_repo() {
  local repo_dir="$1"
  # ignore filter
  if matches_ignore "$repo_dir"; then
    return 0
  fi

  cd "$repo_dir"
  [[ -d .git ]] || return 0

  local origin_url pair owner repo
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "$origin_url" ]] || return 0

  pair="$(parse_owner_repo "$origin_url")"
  [[ -n "$pair" ]] || return 0
  owner="${pair%/*}"
  repo="${pair#*/}"

  echo "==> $(pwd)"

  if [[ "$owner" == "$USER_GH" ]]; then
    local desired_origin; desired_origin="$(gh_url "$USER_GH" "$repo")"
    if [[ "$origin_url" == "$desired_origin" ]]; then
      echo "   - origin already your repo ($desired_origin)"
    else
      echo "   - normalize origin -> $desired_origin"
      [[ "$EXECUTE" -eq 1 ]] && git remote set-url origin "$desired_origin"
    fi
    if git remote | grep -qx upstream; then
      if [[ "$ADD_UPSTREAM" -eq 0 ]]; then
        echo "   - removing upstream (per --no-upstream)"
        [[ "$EXECUTE" -eq 1 ]] && git remote remove upstream
      fi
    fi
    echo
    return 0
  fi

  # Not your repo -> ensure fork and rewire
  echo "   - origin belongs to $owner/$repo"
  create_fork_if_missing "$owner" "$repo"

  local desired_origin desired_upstream
  desired_origin="$(gh_url "$USER_GH" "$repo")"
  desired_upstream="$(gh_url "$owner" "$repo")"

  echo "   - set origin -> $desired_origin"
  [[ "$EXECUTE" -eq 1 ]] && git remote set-url origin "$desired_origin"

  if [[ "$ADD_UPSTREAM" -eq 1 ]]; then
    if git remote | grep -qx upstream; then
      echo "   - set upstream -> $desired_upstream"
      [[ "$EXECUTE" -eq 1 ]] && git remote set-url upstream "$desired_upstream"
    else
      echo "   - add upstream -> $desired_upstream"
      [[ "$EXECUTE" -eq 1 ]] && git remote add upstream "$desired_upstream"
    fi
  else
    if git remote | grep -qx upstream; then
      echo "   - removing upstream (per --no-upstream)"
      [[ "$EXECUTE" -eq 1 ]] && git remote remove upstream
    fi
  fi

  echo
}

main() {
  need git
  need gh
  parse_args "$@"
  ensure_user

  # Walk repos and process
  while IFS= read -r gitdir; do
    process_repo "$(dirname "$gitdir")"
  done < <(find "$ROOT" -type d -name .git -prune -maxdepth "$MAXDEPTH" 2>/dev/null)
}

main "$@"