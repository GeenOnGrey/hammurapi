#!/usr/bin/env bash
# Hammurapi installer for a single host (docker compose).
#
#   install/install.sh --demo                 # try it: fake GitLab + scripted agent
#   install/install.sh                        # interactive: your GitHub or GitLab
#   install/install.sh --provider gitlab --yes   # non-interactive, values from the environment
#
# Environment overrides (non-interactive): PUBLIC_URL GIT_PROVIDER GIT_BASE_URL GIT_REPO
# GIT_DEFAULT_BRANCH GITLAB_CLIENT_ID GITLAB_CLIENT_SECRET GITHUB_APP_ID GITHUB_CLIENT_ID
# GITHUB_CLIENT_SECRET GITHUB_APP_PRIVATE_KEY BOOTSTRAP_ADMINS AGENT_TARGET ACP_AGENT_ENV
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARENT=$(dirname "$ROOT")
REPO_BASE=${REPO_BASE:-https://github.com/GeenOnGrey}
DEMO=0; YES=0; PROVIDER=${GIT_PROVIDER:-}; VOICE=0

usage() { sed -n '2,12p' "$0"; exit 0; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --demo) DEMO=1 ;;
    --yes|-y) YES=1 ;;
    --provider) PROVIDER=$2; shift ;;
    --voice) VOICE=1 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { # ask VAR "Question" default
  local var=$1 q=$2 def=${3:-} cur=${!1:-}
  [[ -n $cur ]] && return
  if [[ $YES == 1 ]]; then printf -v "$var" '%s' "$def"; return; fi
  read -r -p "$q${def:+ [$def]}: " cur
  printf -v "$var" '%s' "${cur:-$def}"
}
secret() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }

say "Checking prerequisites"
command -v docker >/dev/null || die "Docker is required: https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
docker info >/dev/null 2>&1 || die "The Docker daemon is not running"

for repo in hammurapi-core hammurapi-web; do
  if [[ ! -d $PARENT/$repo ]]; then
    command -v git >/dev/null || die "$repo is missing next to hammurapi and git is not installed"
    say "Cloning $repo"
    git clone --depth 1 "$REPO_BASE/$repo.git" "$PARENT/$repo"
  fi
done

ENV_FILE=$ROOT/.env
if [[ -f $ENV_FILE ]]; then
  if [[ $YES == 1 ]]; then warn ".env exists, keeping it"; KEEP=1
  else read -r -p ".env exists. Keep it? [Y/n] " a; [[ ${a:-y} =~ ^[Nn] ]] && KEEP=0 || KEEP=1; fi
else KEEP=0; fi

if [[ $KEEP == 0 ]]; then
  cp "$ROOT/.env.example" "$ENV_FILE"
  set_env() { # set_env KEY VALUE (value may contain / & |)
    local k=$1 v=$2
    v=${v//\\/\\\\}; v=${v//&/\\&}; v=${v//|/\\|}
    sed -i.bak "s|^$k=.*|$k=$v|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  }
  set_env TOKEN_ENCRYPTION_KEY "$(secret)"
  set_env WEBHOOK_SECRET "$(secret | tr -dc 'A-Za-z0-9' | head -c 32)"

  if [[ $DEMO == 1 ]]; then
    say "Demo mode: in-memory fake GitLab and a scripted agent (no real LLM)"
    set_env PUBLIC_URL http://localhost:8080
    set_env GIT_PROVIDER gitlab
    set_env GIT_BASE_URL http://fakegitlab:8929
    set_env GIT_OAUTH_URL http://localhost:8929
    set_env GIT_REPO demo/specs
    set_env GITLAB_CLIENT_ID demo
    set_env GITLAB_CLIENT_SECRET demo
    set_env BOOTSTRAP_ADMINS admin
  else
    ask PUBLIC_URL "Public URL of Hammurapi" "http://localhost:8080"
    ask PROVIDER "Git provider (github/gitlab)" "gitlab"
    [[ $PROVIDER == github || $PROVIDER == gitlab ]] || die "provider must be github or gitlab"
    if [[ $PROVIDER == gitlab ]]; then ask GIT_BASE_URL "GitLab URL" "https://gitlab.com"
    else ask GIT_BASE_URL "GitHub URL (GitHub Enterprise: your host)" "https://github.com"; fi
    ask GIT_REPO "Specifications repository (owner/name)" ""
    ask GIT_DEFAULT_BRANCH "Default branch" "main"
    if [[ $PROVIDER == gitlab ]]; then
      ask GITLAB_CLIENT_ID "GitLab OAuth application ID" ""
      ask GITLAB_CLIENT_SECRET "GitLab OAuth application secret" ""
      set_env GITLAB_CLIENT_ID "$GITLAB_CLIENT_ID"; set_env GITLAB_CLIENT_SECRET "$GITLAB_CLIENT_SECRET"
    else
      ask GITHUB_APP_ID "GitHub App ID" ""
      ask GITHUB_CLIENT_ID "GitHub App client ID" ""
      ask GITHUB_CLIENT_SECRET "GitHub App client secret" ""
      set_env GITHUB_APP_ID "$GITHUB_APP_ID"; set_env GITHUB_CLIENT_ID "$GITHUB_CLIENT_ID"; set_env GITHUB_CLIENT_SECRET "$GITHUB_CLIENT_SECRET"
    fi
    ask BOOTSTRAP_ADMINS "Logins of the first administrators (comma-separated)" ""
    ask AGENT_TARGET "Agent: fake (scripted, for testing) or claude (Claude Code over ACP)" "fake"
    [[ -n $GIT_REPO ]] || die "the repository is required"
    set_env PUBLIC_URL "${PUBLIC_URL%/}"
    set_env GIT_PROVIDER "$PROVIDER"
    set_env GIT_BASE_URL "${GIT_BASE_URL%/}"
    set_env GIT_REPO "$GIT_REPO"
    set_env GIT_DEFAULT_BRANCH "$GIT_DEFAULT_BRANCH"
    set_env BOOTSTRAP_ADMINS "$BOOTSTRAP_ADMINS"
    set_env AGENT_TARGET "$AGENT_TARGET"
    if [[ $AGENT_TARGET == claude ]]; then
      set_env ACP_AGENT_COMMAND claude-agent-acp
      ask ANTHROPIC_API_KEY "Anthropic API key for the agent" ""
      set_env ACP_AGENT_ENV "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
    fi
  fi
  chmod 600 "$ENV_FILE"
  say "Wrote $ENV_FILE"
fi

profiles=()
[[ $DEMO == 1 ]] && profiles+=(--profile demo)
[[ $VOICE == 1 ]] && profiles+=(--profile voice)
say "Building and starting containers (first run takes a few minutes)"
(cd "$ROOT" && docker compose "${profiles[@]}" up -d --build)

say "Waiting for the api to become ready"
for _ in $(seq 1 90); do
  if curl -fsS http://localhost:9100/readyz >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[[ ${ready:-0} == 1 ]] || die "the api is not ready; see: docker compose logs api"

# shellcheck disable=SC1090
source <(grep -E '^(PUBLIC_URL|WEBHOOK_SECRET|GIT_PROVIDER)=' "$ENV_FILE")
cat <<EOF

$(printf '\033[1;32m')Hammurapi is running.$(printf '\033[0m')

  Open:            $PUBLIC_URL
EOF
if [[ $DEMO == 1 ]]; then
  cat <<EOF
  Sign in as:      admin (global administrator), anna or oleg — any login works
  Fake GitLab:     http://localhost:8929  (development only)
EOF
else
  cat <<EOF
  OAuth callback:  $PUBLIC_URL/api/v1/auth/callback   (register it in your $GIT_PROVIDER app)
  Webhook URL:     $PUBLIC_URL/hooks/v1/git   (push events)
  Webhook secret:  $WEBHOOK_SECRET
  The repository needs rules/<area>/template.md and fix-template.md: copy $ROOT/rules.
EOF
fi
cat <<EOF

  Logs:     docker compose logs -f api worker
  Cleaner:  docker compose run --rm api cleaner
  Stop:     docker compose down
EOF
