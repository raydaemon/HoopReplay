#!/usr/bin/env bash

# Apply the SQL migrations in web/supabase/migrations to the linked Supabase project.
#
# The Android and Web clients both talk to the hosted project, so a migration that only
# exists as a file is invisible to them: the app starts asking for a table that is not
# there yet. This script is the one step between writing a migration and the clients
# being able to use it.
#
# Usage:
#   scripts/supabase-migrate.sh              Show pending migrations, then apply them
#   scripts/supabase-migrate.sh --list       Only show local vs remote migration state
#   SUPABASE_PROFILE=<name> scripts/supabase-migrate.sh
#                                            Run as a scripts/supabase.sh profile

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_DIR="$ROOT_DIR/web"
# This repository is linked to the Conn/ConnectedAI Supabase account. Keep the
# migration command deterministic so a different global Supabase login cannot
# accidentally be used for this project.
SUPABASE_PROFILE_NAME="connectedai"
PROFILES_DIR="${SUPABASE_PROFILES_DIR:-$HOME/.supabase/profiles}"

list_only=0
for argument in "$@"; do
  case "$argument" in
    --list) list_only=1 ;;
    -h|--help) sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      echo "Unknown option: $argument" >&2
      exit 1
      ;;
  esac
done

command -v supabase >/dev/null 2>&1 || {
  echo "Missing required command: supabase" >&2
  exit 1
}

[[ -d "$WEB_DIR/supabase/migrations" ]] || {
  echo "Error: missing $WEB_DIR/supabase/migrations" >&2
  exit 1
}

# The CLI resolves the linked project from web/supabase, so every call runs from there.
cd "$WEB_DIR"

supabase_cli() {
  local profile_path="$PROFILES_DIR/$SUPABASE_PROFILE_NAME.yaml"
  [[ -f "$profile_path" ]] || {
    echo "Missing required Supabase profile: $profile_path" >&2
    echo "Run: scripts/supabase.sh login $SUPABASE_PROFILE_NAME" >&2
    exit 1
  }
  supabase --profile "$profile_path" "$@"
}

[[ -f "supabase/.temp/project-ref" ]] || {
  echo "Error: no linked project. Run: supabase link --project-ref <ref>" >&2
  exit 1
}
echo "Project: $(cat supabase/.temp/project-ref)"
echo

echo "Migration status:"
supabase_cli migration list || {
  echo
  echo "Could not read the remote migration list. Log in first (scripts/supabase.sh login <profile>)." >&2
  exit 1
}

[[ "$list_only" -eq 1 ]] && exit 0

# No confirmation prompt: running this script is already the decision to migrate.
echo
supabase_cli db push --include-all --yes
