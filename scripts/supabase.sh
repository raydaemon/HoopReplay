#!/usr/bin/env bash

# Keep several Supabase profiles side by side under one macOS user.
#
# The Supabase CLI already supports `--profile <file>`: each profile YAML under
# ~/.supabase/profiles/<ProfileName>.yaml owns its own credential slot, so
# logging into one never clobbers another. This wrapper mirrors
# scripts/vercel.sh so both clouds are driven the same way.

set -euo pipefail

PROFILES_DIR="${SUPABASE_PROFILES_DIR:-$HOME/.supabase/profiles}"
ACTIVE_PROFILE_FILE="${SUPABASE_ACTIVE_PROFILE_FILE:-$HOME/.supabase/profile}"

command -v supabase >/dev/null 2>&1 || {
  echo "Missing required command: supabase" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/supabase.sh login <profile>        Log in and store credentials for <profile>
  scripts/supabase.sh list                   List known profiles and the active one
  scripts/supabase.sh who <profile>          Check <profile> against the API and show its projects
  scripts/supabase.sh path <profile>         Print the profile file of <profile>
  scripts/supabase.sh run <profile> [args]   Run a supabase command as <profile>
  scripts/supabase.sh use <profile>          Make <profile> the default for bare `supabase`
  scripts/supabase.sh logout <profile>       Log out and remove the stored profile

Profiles live in $HOME/.supabase/profiles/<ProfileName>.yaml (override the
parent with SUPABASE_PROFILES_DIR).
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

profile_file() {
  printf '%s/%s.yaml\n' "$PROFILES_DIR" "$1"
}

require_existing_profile() {
  local file
  file="$(profile_file "$1")"
  [[ -f "$file" ]] || {
    echo "Unknown profile: $1. Run: scripts/supabase.sh login $1" >&2
    exit 1
  }
}

write_profile_file() {
  local profile_name="$1"
  local file="$2"

  cat >"$file" <<EOF
# Supabase CLI profile for the $profile_name account.
# Use with: supabase --profile $file <command>
# Each profile keeps its own credential slot, so this account can stay logged in
# alongside the other profiles without either one clobbering the other.
name: $profile_name
api_url: https://api.supabase.com
dashboard_url: https://supabase.com/dashboard
project_host: supabase.co
pooler_host: supabase.com
EOF
  chmod 600 "$file"
}

active_profile_file() {
  [[ -f "$ACTIVE_PROFILE_FILE" ]] || return 0
  tr -d '[:space:]' <"$ACTIVE_PROFILE_FILE"
}

command_name="${1:-}"
[[ -n "$command_name" ]] || usage
shift || true

case "$command_name" in
  login)
    require_profile_name "${1:-}"
    profile_name="$1"
    file="$(profile_file "$profile_name")"
    mkdir -p "$PROFILES_DIR"
    chmod 700 "$PROFILES_DIR"
    [[ -f "$file" ]] || write_profile_file "$profile_name" "$file"
    shift
    supabase --profile "$file" login --name "$profile_name" "$@"
    echo
    echo "Profile '$profile_name' is stored in $file"
    echo "Use it with: supabase --profile $file <command>"
    ;;
  list)
    [[ -d "$PROFILES_DIR" ]] || {
      echo "No profiles yet. Run: scripts/supabase.sh login <profile>" >&2
      exit 1
    }
    active="$(active_profile_file)"
    found_any=0
    for file in "$PROFILES_DIR"/*.yaml; do
      [[ -f "$file" ]] || continue
      found_any=1
      profile_name="$(basename "$file" .yaml)"
      marker=" "
      [[ "$file" == "$active" ]] && marker="*"
      printf '%s %-24s %s\n' "$marker" "$profile_name" "$file"
    done
    [[ "$found_any" -eq 1 ]] || {
      echo "No profiles yet. Run: scripts/supabase.sh login <profile>" >&2
      exit 1
    }
    [[ -n "$active" ]] && echo && echo "* is the default profile used by a bare \`supabase\` command."
    ;;
  who)
    require_profile_name "${1:-}"
    require_existing_profile "$1"
    file="$(profile_file "$1")"
    projects="$(supabase --profile "$file" projects list --output json 2>/dev/null || true)"
    [[ -n "$projects" ]] || {
      echo "Profile '$1' is not authenticated. Run: scripts/supabase.sh login $1" >&2
      exit 1
    }
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$projects" | jq -r '.[] | "\(.ref)\t\(.name)"'
    else
      printf '%s\n' "$projects"
    fi
    ;;
  path)
    require_profile_name "${1:-}"
    require_existing_profile "$1"
    profile_file "$1"
    ;;
  run)
    require_profile_name "${1:-}"
    require_existing_profile "$1"
    profile_name="$1"
    shift
    [[ $# -ge 1 ]] || {
      echo "Missing supabase command to run as $profile_name" >&2
      usage
    }
    exec supabase --profile "$(profile_file "$profile_name")" "$@"
    ;;
  use)
    require_profile_name "${1:-}"
    require_existing_profile "$1"
    profile_file "$1" >"$ACTIVE_PROFILE_FILE"
    echo "Default profile is now '$1'"
    ;;
  logout)
    require_profile_name "${1:-}"
    require_existing_profile "$1"
    file="$(profile_file "$1")"
    supabase --profile "$file" logout --yes || true
    if [[ "$(active_profile_file)" == "$file" ]]; then
      rm -f "$ACTIVE_PROFILE_FILE"
      echo "Cleared the default profile; bare \`supabase\` now uses the built-in default."
    fi
    rm -f "$file"
    echo "Removed profile '$1'"
    ;;
  *)
    echo "Unknown command: $command_name" >&2
    usage
    ;;
esac
