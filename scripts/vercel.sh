#!/usr/bin/env bash

# Keep several Vercel profiles side by side under one macOS user.
#
# Every profile gets its own global `.vercel` directory under ~/.vercel, so
# logging into one never overwrites the credentials of another. Point any Vercel
# command at a profile with
# `vercel --global-config "$(scripts/vercel.sh path <profile>)"`.

set -euo pipefail

PROFILES_DIR="${VERCEL_PROFILES_DIR:-$HOME/.vercel}"

command -v vercel >/dev/null 2>&1 || {
  echo "Missing required command: vercel" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/vercel.sh login <profile>        Log in and store credentials for <profile>
  scripts/vercel.sh list                   List known profiles and who each one is
  scripts/vercel.sh who <profile>          Print the Vercel user behind <profile>
  scripts/vercel.sh path <profile>         Print the global config directory of <profile>
  scripts/vercel.sh run <profile> [args]   Run a vercel command as <profile>
  scripts/vercel.sh logout <profile>       Log out and remove the stored credentials

Profiles live in $HOME/.vercel/<ProfileName> (override the parent with
VERCEL_PROFILES_DIR).
EOF
  exit 1
}

require_profile_name() {
  [[ $# -ge 1 && -n "${1:-}" ]] || {
    echo "Missing profile name" >&2
    usage
  }
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Invalid profile name: $1 (use letters, digits, dot, dash, underscore)" >&2
    exit 1
  }
}

profile_dir() {
  printf '%s/%s\n' "$PROFILES_DIR" "$1"
}

require_existing_profile() {
  local directory
  directory="$(profile_dir "$1")"
  [[ -d "$directory" ]] || {
    echo "Unknown profile: $1. Run: scripts/vercel.sh login $1" >&2
    exit 1
  }
}

whoami_for() {
  vercel --global-config "$(profile_dir "$1")" whoami 2>/dev/null || true
}

command_name="${1:-}"
[[ -n "$command_name" ]] || usage
shift || true

case "$command_name" in
  login)
    require_profile_name "${1:-}"
    profile_name="$1"
    directory="$(profile_dir "$profile_name")"
    mkdir -p "$directory"
    chmod 700 "$directory"
    shift
    vercel --global-config "$directory" login "$@"
    current_user="$(whoami_for "$profile_name")"
    [[ -n "$current_user" ]] || {
      echo "Login did not produce a usable session for $profile_name" >&2
      exit 1
    }
    echo
    echo "Profile '$profile_name' is now $current_user"
    echo "Use it with: vercel --global-config $directory <command>"
    ;;
  list)
    [[ -d "$PROFILES_DIR" ]] || {
      echo "No profiles yet. Run: scripts/vercel.sh login <profile>" >&2
      exit 1
    }
    found_any=0
    for directory in "$PROFILES_DIR"/*/; do
      [[ -f "$directory/auth.json" ]] || continue
      found_any=1
      profile_name="$(basename "$directory")"
      current_user="$(whoami_for "$profile_name")"
      printf '%-24s %s\n' "$profile_name" "${current_user:-<signed out>}"
    done
    [[ "$found_any" -eq 1 ]] || {
      echo "No profiles yet. Run: scripts/vercel.sh login <profile>" >&2
      exit 1
    }
    ;;
  who)
    require_profile_name "${1:-}"
    require_existing_profile "$1"
    current_user="$(whoami_for "$1")"
    [[ -n "$current_user" ]] || {
      echo "Profile '$1' is signed out. Run: scripts/vercel.sh login $1" >&2
      exit 1
    }
    echo "$current_user"
    ;;
  path)
    require_profile_name "${1:-}"
    require_existing_profile "$1"
    profile_dir "$1"
    ;;
  run)
    require_profile_name "${1:-}"
    require_existing_profile "$1"
    profile_name="$1"
    shift
    [[ $# -ge 1 ]] || {
      echo "Missing vercel command to run as $profile_name" >&2
      usage
    }
    exec vercel --global-config "$(profile_dir "$profile_name")" "$@"
    ;;
  logout)
    require_profile_name "${1:-}"
    require_existing_profile "$1"
    directory="$(profile_dir "$1")"
    vercel --global-config "$directory" logout || true
    rm -rf "$directory"
    echo "Removed profile '$1'"
    ;;
  *)
    echo "Unknown command: $command_name" >&2
    usage
    ;;
esac
