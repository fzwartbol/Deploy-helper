#!/usr/bin/env bash
# sync-deploy.sh
# Syncs OpenShift deploy changes across Bitbucket repos with per-repo name
# substitution. Sealed Secrets are never blindly overwritten — encrypted values
# are blanked on new files so each team re-seals for their own cluster.
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

Syncs OpenShift deploy repo changes to all configured Bitbucket repos,
substitutes app/service/namespace names, pushes a branch, and opens a PR.

Sealed Secrets are handled specially:
  - Modified  → skipped (each cluster keeps its own encrypted values)
  - Added     → copied with encryptedData blanked (team must re-seal)
  - Deleted   → deleted in target
  - Renamed   → renamed; encryptedData blanked (team must re-seal)

Options:
  --from <ref>       Start ref in source repo  (default: HEAD~1)
  --to <ref>         End ref in source repo    (default: HEAD)
  --targets <names>  Comma-separated names from repos.json, or "all" (default: all)
  --dry-run          Preview changes without cloning or pushing
  --config <file>    Path to config file       (default: ./repos.json)
  -h, --help         Show this help

Environment:
  BITBUCKET_USER   Bitbucket username
  BITBUCKET_TOKEN  Bitbucket app password with repo + PR write access

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
[[ -n "${BITBUCKET_USER:-}" ]]  || { log_error "BITBUCKET_USER is not set";  exit 1; }
[[ -n "${BITBUCKET_TOKEN:-}" ]] || { log_error "BITBUCKET_TOKEN is not set"; exit 1; }
for cmd in jq git curl awk; do
  command -v "$cmd" >/dev/null || { log_error "'$cmd' is required but not installed"; exit 1; }
done

# ── Load config ───────────────────────────────────────────────────────────────
SOURCE_REPO=$(jq -r '.source.repo'           "$CONFIG_FILE")
SOURCE_SUBS=$(jq -c '.source.substitutions'  "$CONFIG_FILE")
BASE_BRANCH=$(jq -r '.pr.base_branch // "main"'          "$CONFIG_FILE")
PR_TITLE_PREFIX=$(jq -r '.pr.title_prefix // "chore(sync): "' "$CONFIG_FILE")
TARGET_COUNT=$(jq '.targets | length'        "$CONFIG_FILE")

mkdir -p "$WORK_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

is_target_included() {
  [[ "$FILTER_TARGETS" == "all" ]] && return 0
  IFS=',' read -ra arr <<< "$FILTER_TARGETS"
  for t in "${arr[@]}"; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

is_text_file()     { grep -qI '' "$1" 2>/dev/null; }
is_sealed_secret() { is_text_file "$1" && grep -q 'kind:[[:space:]]*SealedSecret' "$1" 2>/dev/null; }

clone_or_update() {
  local repo="$1" dir="$2"
  local url="https://${BITBUCKET_USER}:${BITBUCKET_TOKEN}@bitbucket.org/${repo}.git"
  if [[ -d "$dir/.git" ]]; then
    log_info "Updating $repo"
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

# Builds a sed substitution script. Uses jq to sort source values by length
# (longest first) so that longer values are replaced before any sub-string match.
build_sed_script() {
  local src="$1" tgt="$2" sed_script="" sv tv src_esc tgt_esc
  while IFS=$'\t' read -r sv tv; do
    [[ -z "$sv" || -z "$tv" ]] && continue
    src_esc=$(printf '%s' "$sv" | sed 's/[[\.*^$()+?{|]/\\&/g')
    tgt_esc=$(printf '%s' "$tv" | sed 's/[&/\\]/\\&/g')
    sed_script+="s/${src_esc}/${tgt_esc}/g;"
  done < <(jq -rn --argjson s "$src" --argjson t "$tgt" \
    '$s | to_entries
     | map(select($t[.key] != null and .value != $t[.key]))
     | sort_by(.value | length) | reverse
     | .[] | [.value, $t[.key]] | @tsv')
  echo "$sed_script"
}

apply_subs() {
  local file="$1" sed_script="$2"
  [[ -z "$sed_script" ]] && return 0
  is_text_file "$file" || { log_warn "Skipping binary: $(basename "$file")"; return 0; }
  sed -i "$sed_script" "$file"
}

# Blanks all values under spec.encryptedData, keeping the YAML structure so
# the developer can identify which keys need to be re-sealed with kubeseal.
strip_encrypted_data() {
  awk '
    /^  encryptedData:/ { in_enc=1; print; next }
    in_enc && /^    [^[:space:]]/ {
      sub(/:[[:space:]].*$/, ": \"\"  # TODO: kubeseal for this cluster")
      print; next
    }
    { in_enc=0; print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# Copies a file from source to target dir and applies substitutions.
# Returns 1 (non-fatal) if source file is missing.
copy_and_apply() {
  local src_rel="$1" tgt_rel="$2" tgt_dir="$3" sed_script="$4"
  local src_abs="$SOURCE_DIR/$src_rel"
  local tgt_abs="$tgt_dir/$tgt_rel"
  if [[ ! -f "$src_abs" ]]; then
    log_warn "Source missing: $src_rel — skipping"
    return 1
  fi
  mkdir -p "$(dirname "$tgt_abs")"
  cp "$src_abs" "$tgt_abs"
  apply_subs "$tgt_abs" "$sed_script"
}

create_bitbucket_pr() {
  local repo="$1" branch="$2" title="$3" body="$4"
  local payload response http_code body_json
  payload=$(jq -n \
    --arg title  "$title"       \
    --arg body   "$body"        \
    --arg branch "$branch"      \
    --arg base   "$BASE_BRANCH" \
    '{title:$title, description:$body,
      source:{branch:{name:$branch}},
      destination:{branch:{name:$base}},
      close_source_branch:true}')

  response=$(curl -s -w "\n%{http_code}" -X POST \
    -u "${BITBUCKET_USER}:${BITBUCKET_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.bitbucket.org/2.0/repositories/${repo}/pullrequests" \
    -d "$payload")

  http_code=$(tail  -n1  <<< "$response")
  body_json=$(head  -n-1 <<< "$response")

  if [[ "$http_code" == "201" ]]; then
    jq -r '.links.html.href' <<< "$body_json"
  elif grep -q "already exists" <<< "$body_json" 2>/dev/null; then
    log_warn "PR already open for branch $branch on $repo — skipping"
  else
    log_error "Bitbucket API $http_code: $(jq -r '.error.message // .' <<< "$body_json")"
    return 1
  fi
}

# ── Clone / update source ─────────────────────────────────────────────────────
log_section "Source: $SOURCE_REPO  ($FROM_REF → $TO_REF)"
SOURCE_DIR="$WORK_DIR/source"

if $DRY_RUN; then
  log_info "[DRY RUN] Would clone $SOURCE_REPO and diff $FROM_REF..$TO_REF"
  CHANGED_FILES=$'M\texample/deployment.yaml\nA\tsecrets/new-secret.yaml\nD\texample/old.yaml'
else
  clone_or_update "$SOURCE_REPO" "$SOURCE_DIR"
  CHANGED_FILES=$(git -C "$SOURCE_DIR" diff --find-renames --name-status "$FROM_REF" "$TO_REF" || true)
fi

[[ -n "$CHANGED_FILES" ]] || { log_warn "No changes between $FROM_REF and $TO_REF"; exit 0; }

log_info "Changed files:"
while IFS=$'\t' read -r status f1 f2; do
  printf "  [%s] %s\n" "$status" "${f2:-$f1}"
done <<< "$CHANGED_FILES"

CHANGED_FILES_MD=$(while IFS=$'\t' read -r s f1 f2; do
  printf '- `[%s]` `%s`\n' "$s" "${f2:-$f1}"
done <<< "$CHANGED_FILES")

# ── Process each target ───────────────────────────────────────────────────────
PASS=()
FAIL=()

for i in $(seq 0 $((TARGET_COUNT - 1))); do
  TARGET_NAME=$(jq -r ".targets[$i].name"          "$CONFIG_FILE")
  TARGET_REPO=$(jq -r ".targets[$i].repo"          "$CONFIG_FILE")
  TARGET_SUBS=$(jq -c ".targets[$i].substitutions" "$CONFIG_FILE")

  is_target_included "$TARGET_NAME" || continue

  log_section "[$((i+1))/$TARGET_COUNT] $TARGET_NAME → $TARGET_REPO"

  if $DRY_RUN; then
    SED_SCRIPT=$(build_sed_script "$SOURCE_SUBS" "$TARGET_SUBS")
    log_info "[DRY RUN] Branch : $SYNC_BRANCH"
    log_info "[DRY RUN] Subs   : ${SED_SCRIPT:-<none>}"
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
    SEALED_NOTES=()

    while IFS=$'\t' read -r status file1 file2; do
      op="${status:0:1}"          # strip rename similarity score (R095 → R)
      tgt_file="${file2:-$file1}" # for renames: file2 is the new path

      case "$op" in

        D)  # Deletion — safe to mirror regardless of file type
          if [[ -f "$TARGET_DIR/$file1" ]]; then
            git -C "$TARGET_DIR" rm -f "$file1"
            HAS_CHANGES=true
          fi
          ;;

        R)  # Rename — remove old path; copy new path with sealed-secret guard
          [[ -f "$TARGET_DIR/$file1" ]] && git -C "$TARGET_DIR" rm -f "$file1"
          if copy_and_apply "$file2" "$file2" "$TARGET_DIR" "$SED_SCRIPT"; then
            if is_sealed_secret "$TARGET_DIR/$file2"; then
              strip_encrypted_data "$TARGET_DIR/$file2"
              SEALED_NOTES+=("- \`[RENAMED]\` \`$file1\` → \`$file2\` — encryptedData blanked, re-seal for this cluster")
            fi
            git -C "$TARGET_DIR" add "$file2"
            HAS_CHANGES=true
          fi
          ;;

        M)  # Modification — skip Sealed Secrets entirely; they are cluster-specific
          if is_sealed_secret "$SOURCE_DIR/$file1"; then
            SEALED_NOTES+=("- \`[MODIFIED]\` \`$file1\` — **not synced** (cluster-specific encryption); re-seal manually if the secret value changed")
          else
            copy_and_apply "$file1" "$file1" "$TARGET_DIR" "$SED_SCRIPT"
            git -C "$TARGET_DIR" add "$file1"
            HAS_CHANGES=true
          fi
          ;;

        A|C|*)  # Addition / copy — carry structure, blank encrypted values
          if copy_and_apply "$file1" "$file1" "$TARGET_DIR" "$SED_SCRIPT"; then
            if is_sealed_secret "$TARGET_DIR/$file1"; then
              strip_encrypted_data "$TARGET_DIR/$file1"
              SEALED_NOTES+=("- \`[ADDED]\` \`$file1\` — encryptedData blanked, re-seal for this cluster")
            fi
            git -C "$TARGET_DIR" add "$file1"
            HAS_CHANGES=true
          fi
          ;;
      esac
    done <<< "$CHANGED_FILES"

    if ! $HAS_CHANGES; then
      if [[ ${#SEALED_NOTES[@]} -gt 0 ]]; then
        log_warn "$TARGET_NAME: only sealed secret changes (no push needed)"
        log_warn "Manual action required for:"
        printf '  %s\n' "${SEALED_NOTES[@]}"
      else
        log_warn "$TARGET_NAME: no effective changes — skipping"
      fi
      exit 0
    fi

    git -C "$TARGET_DIR" commit -m "$(printf \
      'chore(sync): deploy changes from %s\n\nSource: %s\nRef:    %s → %s\nRun:    %s' \
      "${SOURCE_REPO##*/}" "$SOURCE_REPO" "$FROM_REF" "$TO_REF" "$TIMESTAMP")"
    git -C "$TARGET_DIR" push -u origin "$SYNC_BRANCH"

    # Build optional sealed-secret warning block for PR body
    SEALED_SECTION=""
    if [[ ${#SEALED_NOTES[@]} -gt 0 ]]; then
      SEALED_SECTION="

### ⚠️ Sealed Secrets — manual action required

$(printf '%s\n' "${SEALED_NOTES[@]}")

Run \`kubeseal\` to encrypt the values for this cluster before merging."
    fi

    PR_BODY="## Deploy Sync

Automated sync from \`${SOURCE_REPO}\`

| | |
|---|---|
| **Source repo** | \`${SOURCE_REPO}\` |
| **Ref range**   | \`${FROM_REF}\` → \`${TO_REF}\` |
| **Branch**      | \`${SYNC_BRANCH}\` |
| **Timestamp**   | \`${TIMESTAMP}\` |

### Changed files
${CHANGED_FILES_MD}${SEALED_SECTION}

---
*Auto-generated by sync-deploy.sh — review before merging.*"

    PR_URL=$(create_bitbucket_pr "$TARGET_REPO" "$SYNC_BRANCH" \
      "${PR_TITLE_PREFIX}sync from ${SOURCE_REPO##*/} (${TO_REF})" "$PR_BODY")
    [[ -n "${PR_URL:-}" ]] && log_info "PR: $PR_URL"

  ) && PASS+=("$TARGET_NAME") || { log_error "FAILED: $TARGET_NAME"; FAIL+=("$TARGET_NAME"); }
done

# ── Summary ───────────────────────────────────────────────────────────────────
log_section "Done"
[[ ${#PASS[@]} -gt 0 ]] && log_info  "Success (${#PASS[@]}): ${PASS[*]}"
[[ ${#FAIL[@]} -gt 0 ]] && log_error "Failed  (${#FAIL[@]}): ${FAIL[*]}"
[[ ${#FAIL[@]} -eq 0 ]]
