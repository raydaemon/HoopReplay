#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_DIR="$ROOT_DIR/web"
USERS_CSV="$ROOT_DIR/data/users.csv"
VERCEL_SCOPE="connected-ai"
VERCEL_USER="myconnectedai"
VERCEL_PROJECT="hoopreplay"
VERCEL_PROJECT_ID="prj_v6Au1jupOLHewIEYnbQKBKGDK7Zm"
SUPABASE_PROJECT_REF="ugpkignlnssfllfbznlq"
SUPABASE_PROFILE="${SUPABASE_PROFILE:-$HOME/.supabase/profiles/connectedai.yaml}"
# Vercel credentials live in a per-profile global config directory under
# ~/.vercel/<ProfileName>, so several accounts can coexist under one macOS user.
# Manage them with scripts/vercel.sh; override the profile for a single
# run with VERCEL_PROFILE.
VERCEL_PROFILE="${VERCEL_PROFILE:-connectedai}"
# HoopReplay production deploys use the connectedai Vercel credentials stored
# in this exact local profile directory by default. Set VERCEL_PROFILE_DIR to
# override it for another machine or profile without changing this script.
VERCEL_PROFILE_DIR="${VERCEL_PROFILE_DIR:-/Users/cuper/.vercel/connectedai}"

[[ -f "$VERCEL_PROFILE_DIR/auth.json" ]] || {
  echo "Unknown or signed-out Vercel profile: $VERCEL_PROFILE ($VERCEL_PROFILE_DIR)" >&2
  echo "Run: scripts/vercel.sh login $VERCEL_PROFILE" >&2
  exit 1
}

# Every Vercel call in this script must go through this wrapper so it uses the
# credentials of $VERCEL_PROFILE instead of whichever account logged in last.
vercel_cli() {
  vercel --global-config "$VERCEL_PROFILE_DIR" "$@"
}

for command_name in jq npm supabase vercel; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

[[ -f "$SUPABASE_PROFILE" ]] || {
  echo "Unknown or unsigned-in Supabase profile: $SUPABASE_PROFILE" >&2
  echo "Set SUPABASE_PROFILE to a valid profile YAML file." >&2
  exit 1
}

supabase_cli() {
  supabase --profile "$SUPABASE_PROFILE" "$@"
}

[[ -f "$WEB_DIR/.env.local" ]] || {
  echo "Missing $WEB_DIR/.env.local" >&2
  exit 1
}

[[ -f "$USERS_CSV" ]] || {
  echo "Missing $USERS_CSV" >&2
  exit 1
}

set -a
# shellcheck disable=SC1091
source "$WEB_DIR/.env.local"
set +a

required_env=(
  NEXT_PUBLIC_SUPABASE_URL
  NEXT_PUBLIC_SUPABASE_ANON_KEY
  NEXT_PUBLIC_HOOPREPLAY_SYNC_SPACE
)

for variable_name in "${required_env[@]}"; do
  [[ -n "${!variable_name:-}" ]] || {
    echo "Missing required variable in web/.env.local: $variable_name" >&2
    exit 1
  }
done

current_vercel_user="$(vercel_cli whoami 2>/dev/null)"
[[ "$current_vercel_user" == "$VERCEL_USER" ]] || {
  echo "Wrong Vercel user: expected $VERCEL_USER, got $current_vercel_user" >&2
  exit 1
}

vercel_account_email="$(vercel_cli api /v2/user --raw 2>/dev/null | jq -r '.user.email // empty')"
[[ -n "$vercel_account_email" ]] || {
  echo "Unable to resolve the verified email for Vercel user $VERCEL_USER" >&2
  exit 1
}

# Vercel resolves the deployment's Git author from the commit SHA it detects, not
# from the --meta values below, and refuses to build ("BLOCKED", readyStateReason
# TEAM_ACCESS_REQUIRED) when that author has no access to the team. Catch the
# mismatch here instead of waiting on a deployment that will never build.
head_commit_email="$(git -C "$ROOT_DIR" log -1 --format='%ae')"
[[ "$head_commit_email" == "$vercel_account_email" ]] || {
  echo "Wrong Git author on HEAD: expected $vercel_account_email, got $head_commit_email" >&2
  echo "Vercel would block the build. Re-author the commit, for example:" >&2
  echo "  git -C \"$ROOT_DIR\" commit --amend --author=\"$VERCEL_USER <$vercel_account_email>\" --no-edit" >&2
  exit 1
}

linked_vercel_project="$(jq -r '.projectId // empty' "$WEB_DIR/.vercel/project.json")"
[[ "$linked_vercel_project" == "$VERCEL_PROJECT_ID" ]] || {
  echo "Wrong Vercel project link. Run: scripts/vercel.sh run $VERCEL_PROFILE link --project $VERCEL_PROJECT --scope $VERCEL_SCOPE" >&2
  exit 1
}

linked_supabase_ref="$(supabase_cli projects list --output-format json --workdir "$WEB_DIR" | jq -r '.projects[] | select(.linked == true) | .ref')"
[[ "$linked_supabase_ref" == "$SUPABASE_PROJECT_REF" ]] || {
  echo "Wrong Supabase project: expected $SUPABASE_PROJECT_REF, got $linked_supabase_ref" >&2
  exit 1
}

sync_vercel_env() {
  local variable_name="$1"
  local variable_value="${!variable_name}"
  local target

  for target in production preview development; do
    echo "  $variable_name -> $target"
    # Vercel may close stdin before printf exits; disabling pipefail inside the
    # subshell makes the CLI result (not a harmless SIGPIPE) authoritative.
    if (set +o pipefail; printf '%s' "$variable_value" | vercel_cli env update "$variable_name" "$target" --yes --type config --scope "$VERCEL_SCOPE" >/dev/null 2>&1); then
      continue
    fi
    # Either the variable is missing, or it is still stored as a Secret. These
    # are NEXT_PUBLIC_ values that ship to the browser anyway, and Vercel
    # refuses to turn a Secret into Config in place, so drop it and add it back.
    vercel_cli env rm "$variable_name" "$target" --yes --scope "$VERCEL_SCOPE" >/dev/null 2>&1 || true
    (set +o pipefail; printf '%s' "$variable_value" | vercel_cli env add "$variable_name" "$target" --force --type config --scope "$VERCEL_SCOPE" >/dev/null)
  done
}

echo "Applying Supabase migrations..."
supabase_cli db push --linked --yes --workdir "$WEB_DIR"
# Keep warnings visible, but only block deployment for actual advisor errors.
# Leaked-password protection is a paid-plan feature and may legitimately be
# unavailable on a Free project.
supabase_cli db advisors --linked --type all --level warn --fail-on error --workdir "$WEB_DIR"

echo "Syncing Vercel environment variables..."
cd "$WEB_DIR"
for variable_name in "${required_env[@]}"; do
  sync_vercel_env "$variable_name"
done

echo "Installing dependencies and running the production build..."
npm ci

echo "Creating or updating Supabase Auth users from data/users.csv..."
supabase_secret_key="$(
  supabase_cli projects api-keys \
    --project-ref "$SUPABASE_PROJECT_REF" \
    --reveal \
    --output json \
    --workdir "$WEB_DIR" |
    jq -er 'first(.[] | select(.type == "secret" or .name == "service_role") | .api_key)'
)"
SUPABASE_SECRET_KEY="$supabase_secret_key" node "$WEB_DIR/scripts/import-users.mjs" "$USERS_CSV"
unset supabase_secret_key

npm run build

echo "Preparing and deploying the verified source..."
vercel_cli pull --yes --environment=production --scope "$VERCEL_SCOPE" >/dev/null
deployment_result="$(vercel_cli deploy --prod --yes --scope "$VERCEL_SCOPE" \
  --meta "gitCommitAuthorName=$VERCEL_USER" \
  --meta "gitCommitAuthorEmail=$vercel_account_email")"
deployment_url="$(printf '%s' "$deployment_result" | jq -r '.deployment.url // empty' 2>/dev/null || true)"
if [[ -z "$deployment_url" ]]; then
  deployment_url="$deployment_result"
fi

echo
echo "Production deployment: $deployment_url"
