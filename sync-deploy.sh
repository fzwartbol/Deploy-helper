#!/usr/bin/env bash
# Syncs changes from one OpenShift deploy repo to all configured target repos,
# applying per-repo name substitutions, and opens a GitHub PR for each.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/repos.json"
WORK_DIR="$SCRIPT_DIR/.work"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SYNC_BRANCH="sync/deploy-$TIMESTAMP"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${BLUE}==> $*${NC}"; }

usage() { cat <<'EOF'
Usage: sync-deploy.sh [OPTIONS]

Syncs OpenShift deploy repo changes to all configured target repos,
substitutes app/service/namespace names, pushes a branch, and opens a PR.

Options:
  --from <ref>       Start ref in source repo  (default: HEAD~1)
  --to <ref>         End ref in source repo    (default: HEAD)
  --targets <names>  Comma-separated names from repos.json, or "all" (default: all)
  --dry-run          Show what would happen without cloning or pushing
  --config <file>    Path to config file       (default: ./repos.json)
  -h, --help         Show this help

Environment:
  GITHUB_TOKEN  GitHub token with repo + pull_request write permissions

Examples:
  sync-deploy.sh
  sync-deploy.sh --from HEAD~3 --to HEAD
  sync-deploy.sh --from v1.2.0 --to v1.3.0
  sync-deploy.sh --targets app-a,app-b
  sync-deploy.sh --dry-run
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
FROM_REF="HEAD~1"
TO_REF="HEAD"
DRY_RUN=false
FILTER_TARGETS="all"

while [[ $# -gt 0 ]]; do
  case $1 in
    --from)    FROM_REF="$2";       shift 2 ;;
    --to)      TO_REF="$2";         shift 2 ;;
    --targets) FILTER_TARGETS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true;        shift   ;;
    --config)  CONFIG_FILE="$2";    shift 2 ;;
    -h|--help) usage; exit 0        ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || { log_error "Config not found: $CONFIG_FILE"; exit 1; }
[[ -n "${GITHUB_TOKEN:-}" ]] || { log_error "GITHUB_TOKEN is not set"; exit 1; }
for cmd in jq git curl; do
  command -v "$cmd" >/dev/null || { log_error "'$cmd' is required but not installed"; exit 1; }
done

# ── Load config ───────────────────────────────────────────────────────────────
SOURCE_REPO=$(jq -r '.source.repo' "$CONFIG_FILE")
SOURCE_SUBS=$(jq -c '.source.substitutions' "$CONFIG_FILE")
BASE_BRANCH=$(jq -r '.pr.base_branch // "main"' "$CONFIG_FILE")
PR_TITLE_PREFIX=$(jq -r '.pr.title_prefix // "chore(sync): "' "$CONFIG_FILE")
TARGET_COUNT=$(jq '.targets | length' "$CONFIG_FILE")

mkdir -p "$WORK_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

is_target_included() {
  local name="$1"
  [[ "$FILTER_TARGETS" == "all" ]] && return 0
  IFS=',' read -ra arr <<< "$FILTER_TARGETS"
  for t in "${arr[@]}"; do [[ "$t" == "$name" ]] && return 0; done
  return 1
}

is_text_file() {
  grep -qI '' "$1" 2>/dev/null
}

clone_or_update() {
  local repo="$1" dir="$2"
  local url="https://x-access-token:${GITHUB_TOKEN}@github.com/${repo}.git"
  if [[ -d "$dir/.git" ]]; then
    log_info "Updating local clone of $repo"
    git -C "$dir" remote set-url origin "$url"
    git -C "$dir" fetch origin
    git -C "$dir" checkout "$BASE_BRANCH"
    git -C "$dir" reset --hard "origin/$BASE_BRANCH"
  else
    log_info "Cloning $repo"
    git clone "$url" "$dir"
  fi
  git -C "$dir" config user.email "sync-deploy@automation"
  git -C "$dir" config user.name  "Deploy Sync Bot"
}

# Returns a sed script that replaces all source substitution values with target values.
# Longest source values are substituted first to avoid partial-match conflicts.
build_sed_script() {
  local src_subs="$1" tgt_subs="$2"
  local -a pairs=()

  while IFS= read -r key; do
    local src_val tgt_val
    src_val=$(jq -r --arg k "$key" '.[$k]' <<< "$src_subs")
    tgt_val=$(jq -r --arg k "$key" '.[$k]' <<< "$tgt_subs")
    [[ "$src_val" == "null" || "$tgt_val" == "null" || "$src_val" == "$tgt_val" ]] && continue
    pairs+=("${#src_val}:${src_val}:${tgt_val}")
  done < <(jq -r 'keys[]' <<< "$src_subs")

  # Sort by source value length descending to avoid partial substitutions
  local sed_script=""
  while IFS= read -r entry; do
    local rest="${entry#*:}"
    local sv="${rest%%:*}"
    local tv="${rest#*:}"
    local src_esc tgt_esc
    src_esc=$(printf '%s' "$sv" | sed 's/[[\.*^$()+?{|]/\\&/g')
    tgt_esc=$(printf '%s' "$tv" | sed 's/[&/\\]/\\&/g')
    sed_script+="s/${src_esc}/${tgt_esc}/g;"
  done < <(printf '%s\n' "${pairs[@]}" | sort -t: -k1 -rn)

  echo "$sed_script"
}

apply_subs_to_file() {
  local file="$1" sed_script="$2"
  [[ -z "$sed_script" ]] && return 0
  if ! is_text_file "$file"; then
    log_warn "Skipping binary file: $file"
    return 0
  fi
  sed -i "$sed_script" "$file"
}

sync_file_to_target() {
  local src_path="$1" tgt_path="$2" tgt_dir="$3" sed_script="$4"
  local src_abs="$SOURCE_DIR/$src_path"
  local tgt_abs="$tgt_dir/$tgt_path"
  if [[ ! -f "$src_abs" ]]; then
    log_warn "Source file missing: $src_path — skipping"
    return 0
  fi
  mkdir -p "$(dirname "$tgt_abs")"
  cp "$src_abs" "$tgt_abs"
  apply_subs_to_file "$tgt_abs" "$sed_script"
  git -C "$tgt_dir" add "$tgt_path"
}

create_github_pr() {
  local repo="$1" branch="$2" title="$3" body="$4"
  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg body  "$body"  \
    --arg head  "$branch" \
    --arg base  "$BASE_BRANCH" \
    '{title:$title, body:$body, head:$head, base:$base}')

  local response http_code
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$repo/pulls" \
    -d "$payload")

  http_code=$(tail -n1 <<< "$response")
  local body_json
  body_json=$(head -n -1 <<< "$response")

  if [[ "$http_code" == "201" ]]; then
    jq -r '.html_url' <<< "$body_json"
  elif [[ "$http_code" == "422" ]] && grep -q "already exists" <<< "$body_json"; then
    log_warn "PR already exists for branch $branch on $repo — skipping PR creation"
    jq -r '.errors[0].message // "already exists"' <<< "$body_json" || true
  else
    log_error "GitHub API error $http_code: $(jq -r '.message // .' <<< "$body_json")"
    return 1
  fi
}

# ── Clone / update source ─────────────────────────────────────────────────────
log_section "Source: $SOURCE_REPO ($FROM_REF → $TO_REF)"
SOURCE_DIR="$WORK_DIR/source"

if $DRY_RUN; then
  log_info "[DRY RUN] Would clone $SOURCE_REPO and diff $FROM_REF..$TO_REF"
  CHANGED_FILES="M	example/deployment.yaml
M	example/service.yaml"
else
  clone_or_update "$SOURCE_REPO" "$SOURCE_DIR"
  CHANGED_FILES=$(git -C "$SOURCE_DIR" diff --name-status "$FROM_REF" "$TO_REF" || true)
fi

if [[ -z "$CHANGED_FILES" ]]; then
  log_warn "No changes found between $FROM_REF and $TO_REF in $SOURCE_REPO"
  exit 0
fi

log_info "Changed files:"
while IFS=$'\t' read -r status file rest; do
  printf "  [%s] %s\n" "$status" "${rest:-$file}"
done <<< "$CHANGED_FILES"

# Pre-build human-readable change list for PR body
CHANGED_FILES_MD=$(while IFS=$'\t' read -r s f r; do printf '- `[%s]` `%s`\n' "$s" "${r:-$f}"; done <<< "$CHANGED_FILES")

# ── Process each target ───────────────────────────────────────────────────────
PASS=()
FAIL=()

for i in $(seq 0 $((TARGET_COUNT - 1))); do
  TARGET_NAME=$(jq -r ".targets[$i].name" "$CONFIG_FILE")
  TARGET_REPO=$(jq -r ".targets[$i].repo" "$CONFIG_FILE")
  TARGET_SUBS=$(jq -c ".targets[$i].substitutions" "$CONFIG_FILE")

  is_target_included "$TARGET_NAME" || continue

  log_section "[$((i+1))/$TARGET_COUNT] $TARGET_NAME  →  $TARGET_REPO"

  if $DRY_RUN; then
    SED_SCRIPT=$(build_sed_script "$SOURCE_SUBS" "$TARGET_SUBS")
    log_info "[DRY RUN] Branch : $SYNC_BRANCH"
    log_info "[DRY RUN] Sed    : ${SED_SCRIPT:-<no substitutions>}"
    log_info "[DRY RUN] Would push and open PR against $BASE_BRANCH"
    PASS+=("$TARGET_NAME (dry-run)")
    continue
  fi

  (
    set -e
    TARGET_DIR="$WORK_DIR/$TARGET_NAME"

    clone_or_update "$TARGET_REPO" "$TARGET_DIR"
    git -C "$TARGET_DIR" checkout -B "$SYNC_BRANCH"

    SED_SCRIPT=$(build_sed_script "$SOURCE_SUBS" "$TARGET_SUBS")
    HAS_CHANGES=false

    while IFS=$'\t' read -r status file1 file2; do
      case "${status:0:1}" in
        D)
          if [[ -f "$TARGET_DIR/$file1" ]]; then
            git -C "$TARGET_DIR" rm -f "$file1"
            HAS_CHANGES=true
          fi
          ;;
        R)
          # file1 = old path, file2 = new path
          [[ -f "$TARGET_DIR/$file1" ]] && git -C "$TARGET_DIR" rm -f "$file1"
          sync_file_to_target "$file2" "$file2" "$TARGET_DIR" "$SED_SCRIPT"
          HAS_CHANGES=true
          ;;
        A|M|C|*)
          sync_file_to_target "$file1" "$file1" "$TARGET_DIR" "$SED_SCRIPT"
          HAS_CHANGES=true
          ;;
      esac
    done <<< "$CHANGED_FILES"

    if ! $HAS_CHANGES; then
      log_warn "No effective changes for $TARGET_NAME — skipping"
      exit 0
    fi

    COMMIT_MSG="$(printf 'chore(sync): deploy changes from %s\n\nSource: %s\nRef:    %s → %s\nRun:    %s' \
      "${SOURCE_REPO##*/}" "$SOURCE_REPO" "$FROM_REF" "$TO_REF" "$TIMESTAMP")"
    git -C "$TARGET_DIR" commit -m "$COMMIT_MSG"
    git -C "$TARGET_DIR" push -u origin "$SYNC_BRANCH"

    PR_TITLE="${PR_TITLE_PREFIX}sync from ${SOURCE_REPO##*/} (${TO_REF})"
    PR_BODY="## Deploy Sync

Automated sync from [\`${SOURCE_REPO}\`](https://github.com/${SOURCE_REPO})

| | |
|---|---|
| **Source repo** | \`${SOURCE_REPO}\` |
| **Ref range** | \`${FROM_REF}\` → \`${TO_REF}\` |
| **Sync branch** | \`${SYNC_BRANCH}\` |
| **Timestamp** | \`${TIMESTAMP}\` |

### Changed files

${CHANGED_FILES_MD}

---
*Auto-generated by sync-deploy.sh — review substitutions before merging.*"

    PR_URL=$(create_github_pr "$TARGET_REPO" "$SYNC_BRANCH" "$PR_TITLE" "$PR_BODY")
    log_info "PR: $PR_URL"
  ) && PASS+=("$TARGET_NAME") || { log_error "FAILED: $TARGET_NAME"; FAIL+=("$TARGET_NAME"); }
done

# ── Summary ───────────────────────────────────────────────────────────────────
log_section "Done"
[[ ${#PASS[@]} -gt 0 ]] && log_info  "Success (${#PASS[@]}): ${PASS[*]}"
[[ ${#FAIL[@]} -gt 0 ]] && log_error "Failed  (${#FAIL[@]}): ${FAIL[*]}"
[[ ${#FAIL[@]} -eq 0 ]]
