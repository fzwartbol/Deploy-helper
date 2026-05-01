#!/usr/bin/env bash
# sync-deploy.sh
# Syncs OpenShift deploy changes across Bitbucket repos with per-repo name
# substitution, image tag preservation, and Sealed Secret handling.
#
# Sealed Secret rules:
#   Modified  → skipped (cluster-specific encryption, re-seal manually)
#   Added     → if it's a copy of an existing secret (same metadata.name),
#               the target's own version is copied to the new path.
#               If truly new, encryptedData is blanked for re-sealing.
#   Renamed   → target's own sealed secret is moved; if not found, blanked.
#   Deleted   → deleted normally
#
# Image tag rules:
#   image/imageTag/tag YAML values are NEVER copied from source.
#   For modified/renamed files, original target values are restored.
#   For new files no original exists, so source values are kept as-is
#   and the PR body notes which files contain image references.
set -euo pipefail
# Show which line caused an unexpected abort (helps diagnose silent failures).
trap 'printf "[FATAL] Script aborted at line %d\n" "$LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/repos.json"
WORK_DIR="$SCRIPT_DIR/.work"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
# SYNC_BRANCH is computed after FROM_REF/TO_REF are resolved (see below)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
if [[ -n "${MSYSTEM:-}" || -n "${WINDIR:-}" ]]; then
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log_info()    { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
log_section() { printf "\n${BLUE}==> %s${NC}\n" "$*"; }

usage() { cat <<'EOF'
Usage: sync-deploy.sh [OPTIONS]

Syncs OpenShift deploy repo changes to configured Bitbucket repos,
substitutes app/service/namespace names, pushes a branch, and opens a PR.
Any repo in the list can act as source; others become targets.

Options:
  --source <name>    Name of the source repo (from repos list)
  --from <ref>       Start ref in source repo  (default: HEAD~1)
  --to <ref>         End ref in source repo    (default: HEAD)
  --targets <names>  Comma-separated target names, or "all" (default: all)
  --dry-run          Preview changes without cloning or pushing
  --config <file>    Path to config file       (default: ./repos.json)
  -h, --help         Show this help

Environment:
  BITBUCKET_USER   Bitbucket username   (optional — falls back to git credential helper)
  BITBUCKET_TOKEN  Bitbucket app password/token  (optional — same fallback)

  If neither variable is set the script uses whatever credentials are stored
  in your git credential helper (Windows Credential Manager, macOS Keychain,
  ~/.netrc, etc.) — the same ones git itself uses for clone/push.

Examples:
  sync-deploy.sh
  sync-deploy.sh --source source-deploy --from v1.2.0 --to v1.3.0
  sync-deploy.sh --source app-a --targets app-b,app-c
  sync-deploy.sh --source source-deploy --dry-run
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
FROM_REF="HEAD~1"
TO_REF="HEAD"
FROM_EXPLICIT=false
TO_EXPLICIT=false
DRY_RUN=false
FILTER_TARGETS="all"
SOURCE_NAME=""
SOURCE_EXPLICIT=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --source)  SOURCE_NAME="$2"; SOURCE_EXPLICIT=true; shift 2 ;;
    --from)    FROM_REF="$2";    FROM_EXPLICIT=true;   shift 2 ;;
    --to)      TO_REF="$2";      TO_EXPLICIT=true;     shift 2 ;;
    --targets) FILTER_TARGETS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true;        shift   ;;
    --config)  CONFIG_FILE="$2";    shift 2 ;;
    -h|--help) usage; exit 0        ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || { log_error "Config not found: $CONFIG_FILE"; exit 1; }
for cmd in git curl awk; do
  command -v "$cmd" >/dev/null || { log_error "'$cmd' is required but not installed"; exit 1; }
done

# ── Bundled jq (bin/jq-linux-amd64 / bin/jq-windows-amd64.exe shipped in repo)
# jq IS required; the bundled binary is used automatically on Linux/Windows.
JQ_BIN=""
_os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
case "$_os" in
  linux)             _jq_bundle="$SCRIPT_DIR/bin/jq-linux-amd64" ;;
  mingw*|msys*|cygwin*) _jq_bundle="$SCRIPT_DIR/bin/jq-windows-amd64.exe" ;;
  *)                 _jq_bundle="" ;;
esac
[[ -n "${_jq_bundle:-}" && -x "$_jq_bundle" ]] && JQ_BIN="$_jq_bundle"
[[ -z "$JQ_BIN" ]] && command -v jq >/dev/null 2>&1 && JQ_BIN="jq"
unset _os _jq_bundle
true  # jq optional — awk helpers used as primary config parser

# _INTERACTIVE: true when there is a real user at the keyboard.
# Git Bash always sets MSYSTEM (MINGW64/MINGW32/MSYS); use it as a reliable
# Windows-interactive signal because isatty() can mis-report in some Git Bash
# terminal configurations.
_INTERACTIVE=false
if [[ -t 0 || -n "${MSYSTEM:-}" ]]; then
  _INTERACTIVE=true
fi

# ── awk config helpers (no jq dependency at startup) ─────────────────────────
_cf_str() { awk -F'"' -v k="$1" '$2==k && NF>=4 { print $4; exit }' "$CONFIG_FILE"; }
_cf_repo_count() { awk -F'"' '$2=="name" && NF>=4 { c++ } END { print c+0 }' "$CONFIG_FILE"; }
_cf_repo_name() { awk -F'"' -v idx="$1" '$2=="name" && NF>=4 { if (c++==idx) { print $4; exit } }' "$CONFIG_FILE"; }
_cf_repo_path() { awk -F'"' -v idx="$1" '$2=="repo" && NF>=4 { if (c++==idx) { print $4; exit } }' "$CONFIG_FILE"; }
_cf_repo_index() {
  awk -F'"' -v name="$1" '
    $2=="name" && NF>=4 { if ($4==name) { print c+0; f=1; exit } c++ }
    END { if (!f) print "null" }
  ' "$CONFIG_FILE"
}
_cf_repo_label() { printf '%s  [%s]' "$(_cf_repo_name "$1")" "$(_cf_repo_path "$1")"; }
_cf_repo_names_csv() { awk -F'"' '$2=="name" && NF>=4 { printf "%s%s",(sep?", ":""),$4; sep=1 } END{print ""}' "$CONFIG_FILE"; }
_cf_repo_subs() {
  awk -F'"' -v idx="$1" '
    $2=="name" && NF>=4          { nc++ }
    nc==idx+1 && $2=="substitutions" { in_s=1; next }
    in_s && /^[[:space:]]*\}/   { exit }
    in_s && NF>=4 && $2!="" && $3~/^:/ { print $2 "\t" $4 }
  ' "$CONFIG_FILE"
}
_cf_protected_keys() {
  awk '
    /"protected_configmap_keys"/ {
      in_a=1
      rest=$0; sub(/^[^[]*\[/,"",rest)
      while (1) {
        idx=index(rest,"\""); if (!idx) break
        rest=substr(rest,idx+1)
        idx2=index(rest,"\""); if (!idx2) break
        printf "%s%s",(sep?"|":""),substr(rest,1,idx2-1); sep=1
        rest=substr(rest,idx2+1)
      }
      if (index($0,"]")) { in_a=0; printf "\n" }
      next
    }
    in_a && /\]/ { printf "\n"; exit }
    in_a && /"/ {
      s=$0; gsub(/^[^"]*"/,"",s); gsub(/".*$/,"",s)
      printf "%s%s",(sep?"|":""),s; sep=1
    }
    END { if (sep && in_a) printf "\n" }
  ' "$CONFIG_FILE"
}
_json_encode() {
  printf '%s' "$1" | awk '{
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\t/,"\\t")
    printf "%s%s",(NR>1?"\\n":""),$0
  }'
}
_json_pr_payload() {
  printf '{"title":"%s","description":"%s","source":{"branch":{"name":"%s"}},"destination":{"branch":{"name":"%s"}},"close_source_branch":true}' \
    "$(_json_encode "$1")" "$(_json_encode "$2")" "$(_json_encode "$3")" "$(_json_encode "$4")"
}
_json_pr_url() {
  printf '%s' "$1" | tr -d '\n\r' \
    | grep -o '"html":{"href":"[^"]*"' | head -1 \
    | grep -o '"href":"[^"]*"' | cut -d'"' -f4
}
_json_pr_error() {
  local msg
  msg=$(printf '%s' "$1" | tr -d '\n\r' \
    | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "${msg:-$1}"
}

# Sanitizes a git ref so it can be used as a component of a branch name.
# Replaces chars illegal in branch names with '-', collapses runs of '-'.
_sanitize_ref_for_branch() {
  printf '%s' "$1" \
    | sed 's/[[:space:]~^:?*\[\\]/-/g; s/\.\./-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

# ── Load config ───────────────────────────────────────────────────────────────
BASE_BRANCH=$(_cf_str base_branch);   BASE_BRANCH="${BASE_BRANCH:-main}"
PR_TITLE_PREFIX=$(_cf_str title_prefix); PR_TITLE_PREFIX="${PR_TITLE_PREFIX:-chore(sync): }"
REPO_COUNT=$(_cf_repo_count)
PROTECTED_CM_KEYS=$(_cf_protected_keys)
# SOURCE_REPO / SOURCE_SUBS are resolved after source selection (see below)

mkdir -p "$WORK_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

is_target_included() {
  [[ "$1" == "$SOURCE_NAME" ]] && return 1   # source is never its own target
  [[ "$FILTER_TARGETS" == "all" ]] && return 0
  IFS=',' read -ra arr <<< "$FILTER_TARGETS"
  for t in "${arr[@]}"; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

is_text_file()     { grep -qI '' "$1" 2>/dev/null; }
is_sealed_secret() { is_text_file "$1" && grep -q 'kind:[[:space:]]*SealedSecret' "$1" 2>/dev/null; }

# Extracts metadata.name from a SealedSecret YAML file.
get_sealed_secret_name() {
  awk '/^metadata:/{m=1;next} m && /^  name:/{print $2;exit} /^[a-zA-Z]/{m=0}' "$1"
}

# Finds the first SealedSecret file in a directory tree with a given metadata.name.
# Optional third argument: path to exclude from the search (to skip the file itself).
find_sealed_secret_by_name() {
  local name="$1" dir="$2" exclude="${3:-}"
  while IFS= read -r -d '' f; do
    [[ -n "$exclude" && "$f" == "$exclude" ]] && continue
    is_sealed_secret "$f" || continue
    [[ "$(get_sealed_secret_name "$f")" == "$name" ]] && echo "$f" && return 0
  done < <(find "$dir" \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
  return 1
}

# Returns an authenticated Bitbucket HTTPS URL.
# Embeds BITBUCKET_USER/TOKEN when set; otherwise uses a plain URL so that
# git's own credential helper (Windows Credential Manager, macOS Keychain,
# ~/.netrc, etc.) handles authentication transparently.
_bb_url() {
  if [[ -n "${BITBUCKET_USER:-}" && -n "${BITBUCKET_TOKEN:-}" ]]; then
    echo "https://${BITBUCKET_USER}:${BITBUCKET_TOKEN}@bitbucket.org/${1}.git"
  else
    echo "https://bitbucket.org/${1}.git"
  fi
}

clone_or_update() {
  local repo="$1" dir="$2"
  local url; url=$(_bb_url "$repo")
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
  # Use the local machine's git identity for commits in the cloned repo
  git -C "$dir" config user.email \
    "$(git config --global user.email 2>/dev/null || echo 'sync-deploy@automation')"
  git -C "$dir" config user.name \
    "$(git config --global user.name  2>/dev/null || echo 'Deploy Sync Bot')"
}

# Builds a sed substitution script sorted longest-source-value first to prevent
# partial-string matches (e.g. "app" clobbering part of "app-service").
# Receives $src and $tgt as TAB-separated key\tvalue lines (from _cf_repo_subs).
build_sed_script() {
  local src="$1" tgt="$2" sed_script="" sv tv src_esc tgt_esc
  local src_f tgt_f
  src_f=$(mktemp "${TMPDIR:-/tmp}/.subs_src_XXXXXX")
  tgt_f=$(mktemp "${TMPDIR:-/tmp}/.subs_tgt_XXXXXX")
  printf '%s\n' "$src" > "$src_f"
  printf '%s\n' "$tgt" > "$tgt_f"
  while IFS=$'\t' read -r sv tv; do
    [[ -z "$sv" || -z "$tv" ]] && continue
    src_esc=$(printf '%s' "$sv" | sed 's/[[\.*^$()+?{|/]/\\&/g')
    tgt_esc=$(printf '%s' "$tv" | sed 's/[&|\\]/\\&/g')
    sed_script+="s|${src_esc}|${tgt_esc}|g;"
  done < <(awk -F'\t' '
    NR==FNR { if (NF==2) src[$1]=$2; next }
    NF==2 && $1 in src && src[$1]!=$2 {
      sv=src[$1]; tv=$2; l=length(sv)
      svals[cnt]=sv; tvals[cnt]=tv; lens[cnt]=l; cnt++
    }
    END {
      for (i=1;i<cnt;i++) {
        sv2=svals[i]; tv2=tvals[i]; l2=lens[i]; j=i-1
        while (j>=0 && lens[j]<l2) {
          svals[j+1]=svals[j]; tvals[j+1]=tvals[j]; lens[j+1]=lens[j]; j--
        }
        svals[j+1]=sv2; tvals[j+1]=tv2; lens[j+1]=l2
      }
      for (i=0;i<cnt;i++) print svals[i] "\t" tvals[i]
    }
  ' "$src_f" "$tgt_f")
  rm -f "$src_f" "$tgt_f"
  echo "$sed_script"
}

apply_subs() {
  local file="$1" sed_script="$2"
  [[ -z "$sed_script" ]] && return 0
  is_text_file "$file" || { log_warn "Skipping binary: $(basename "$file")"; return 0; }
  sed -i "$sed_script" "$file"
}

# Blanks all values under spec.encryptedData so the team knows exactly which
# keys to re-seal with kubeseal for their own cluster.
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

# After copying a file from source, restores image-related lines from the
# original target file so environment-specific image tags are never overwritten.
# Covers Deployment-style keys (image, imageTag, tag) and kustomization images
# block keys (newTag, newName, digest).
# Matches by YAML key + indentation level to handle multi-container pods correctly.
restore_image_lines() {
  local file="$1" original="$2"
  [[ -f "$original" ]] || return 0
  is_text_file "$file" || return 0
  awk '
    NR == FNR {
      if (/^[[:space:]]*(image|imageTag|tag|newTag|newName|digest):[[:space:]]/) {
        key = $0; sub(/:[[:space:]].*$/, "", key)
        kc[key]++; kl[key, kc[key]] = $0
      }
      next
    }
    /^[[:space:]]*(image|imageTag|tag|newTag|newName|digest):[[:space:]]/ {
      key = $0; sub(/:[[:space:]].*$/, "", key)
      ku[key]++
      if (ku[key] <= kc[key]) { print kl[key, ku[key]]; next }
    }
    { print }
  ' "$original" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Neutralises protected ConfigMap keys in 'theirs' before a three-way merge:
#   - Key exists in target   → set theirs' value = target's value so both sides
#     make the same change relative to base → clean merge keeps the target value.
#   - Key is NEW (not yet in target) → tgt_val entry absent → key passes through
#     unchanged so it is always copied from source on first occurrence.
# Only keys listed in PROTECTED_CM_KEYS are affected; all others merge normally.
# Not called for first-time file copies — source values are used as-is.
neutralize_configmap_keys() {
  local theirs="$1" target="$2"
  [[ -z "${PROTECTED_CM_KEYS:-}" ]] && return 0
  grep -q 'kind:[[:space:]]*ConfigMap' "$theirs" 2>/dev/null || return 0
  [[ -f "$target" ]] || return 0
  is_text_file "$theirs" || return 0
  awk -v pat="$PROTECTED_CM_KEYS" '
    BEGIN { full_pat = "^[[:space:]]+(" pat "):[[:space:]]" }
    NR == FNR {
      if ($0 ~ full_pat) {
        key = $0; sub(/:[[:space:]].*$/, "", key); gsub(/^[[:space:]]+/, "", key)
        tgt_val[key] = $0
      }
      next
    }
    $0 ~ full_pat {
      key = $0; sub(/:[[:space:]].*$/, "", key); gsub(/^[[:space:]]+/, "", key)
      if (key in tgt_val) { print tgt_val[key]; next }
    }
    { print }
  ' "$target" "$theirs" > "$theirs.tmp" && mv "$theirs.tmp" "$theirs"
}

# Checks whether a file contains any image-related YAML keys (Deployment or kustomization style).
has_image_lines() {
  grep -qE '^[[:space:]]*(image|imageTag|tag|newTag|newName|digest):[[:space:]]' "$1" 2>/dev/null
}

# Copies a file from the source repo to the target dir and applies substitutions.
# Returns 1 (non-fatal) when the source file is missing.
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

# Three-way merge a modified file using git merge-file.
#
# base   = source file at FROM_REF with substitutions applied
# theirs = source file at TO_REF with substitutions applied
# ours   = current target file (untouched)
#
# First-time copy (target file absent): theirs is written directly so all
# source values, including image tags and protected ConfigMap keys, are
# carried over as an intentional initial baseline.
#
# Existing file: before merging, env-specific lines in theirs are neutralised
# back to base values (restore_image_lines + neutralize_configmap_keys) so
# git merge-file sees "no change" there and always keeps ours (target) intact.
# Conflict markers are written when both sides changed the same region.
# Returns 0 clean, 1 conflict (markers written), 2+ hard error.
three_way_merge_file() {
  local src_path="$1" tgt_path="$2" tgt_dir="$3" sed_script="$4"
  local src_abs="$SOURCE_DIR/$src_path"
  local tgt_abs="$tgt_dir/$tgt_path"
  local base theirs
  base=$(mktemp   "$WORK_DIR/.3wm_base_XXXXXX")
  theirs=$(mktemp "$WORK_DIR/.3wm_theirs_XXXXXX")

  # base — source file at FROM_REF + substitutions
  # If the file didn't exist at FROM_REF (e.g. added then modified in same
  # range), fall back to a plain full-file copy.
  if ! git -C "$SOURCE_DIR" show "${FROM_REF}:${src_path}" > "$base" 2>/dev/null; then
    rm -f "$base" "$theirs"
    copy_and_apply "$src_path" "$tgt_path" "$tgt_dir" "$sed_script"
    return $?
  fi
  apply_subs "$base" "$sed_script"

  # theirs — source file at TO_REF + substitutions applied
  cp "$src_abs" "$theirs"
  apply_subs "$theirs" "$sed_script"

  # First-time copy: target file does not exist yet.
  # Use theirs as-is — all source values (image tags, protected ConfigMap keys)
  # are carried over intentionally; the PR body will flag image references.
  # Sealed secrets are never passed here (M case filters them out above).
  if [[ ! -f "$tgt_abs" ]]; then
    mkdir -p "$(dirname "$tgt_abs")"
    cp "$theirs" "$tgt_abs"
    rm -f "$base" "$theirs"
    return 0
  fi

  # Existing file: neutralise env-specific lines in theirs so git merge-file
  # sees "no change" there and always keeps the target's own values intact.
  restore_image_lines "$theirs" "$base"
  neutralize_configmap_keys "$theirs" "$tgt_abs"

  local rc=0
  git merge-file \
    -L "target" \
    -L "base (${FROM_REF})" \
    -L "source (${TO_REF})" \
    "$tgt_abs" "$base" "$theirs" || rc=$?

  rm -f "$base" "$theirs"

  if   [[ $rc -eq 1 ]]; then return 1          # conflict — markers written
  elif [[ $rc -gt 1 ]]; then
    log_error "git merge-file failed ($rc) for $tgt_path"
    return 2
  fi
}

create_bitbucket_pr() {
  local repo="$1" branch="$2" title="$3" body="$4"
  local payload response http_code body_json
  if [[ -n "$JQ_BIN" ]] && "$JQ_BIN" --version >/dev/null 2>&1; then
    payload=$("$JQ_BIN" -n \
      --arg title  "$title"       \
      --arg body   "$body"        \
      --arg branch "$branch"      \
      --arg base   "$BASE_BRANCH" \
      '{title:$title, description:$body,
        source:{branch:{name:$branch}},
        destination:{branch:{name:$base}},
        close_source_branch:true}')
  else
    payload=$(_json_pr_payload "$title" "$body" "$branch" "$BASE_BRANCH")
  fi

  # Resolve credentials: prefer explicit env vars, fall back to git credential helper
  # (Windows Credential Manager, macOS Keychain, ~/.netrc, etc.)
  local api_user="${BITBUCKET_USER:-}"
  local api_token="${BITBUCKET_TOKEN:-}"
  if [[ -z "$api_user" || -z "$api_token" ]]; then
    local _cred_raw
    _cred_raw=$(printf 'protocol=https\nhost=bitbucket.org\n' | git credential fill 2>/dev/null) || true
    [[ -z "$api_user"  ]] && api_user=$(printf '%s'  "$_cred_raw" | awk -F= '/^username=/{print $2}')
    [[ -z "$api_token" ]] && api_token=$(printf '%s' "$_cred_raw" | awk -F= '/^password=/{print $2}')
  fi

  local _curl_auth=()
  [[ -n "$api_user" && -n "$api_token" ]] && _curl_auth=(-u "${api_user}:${api_token}")

  response=$(curl -s -w "\n%{http_code}" -X POST \
    "${_curl_auth[@]+"${_curl_auth[@]}"}" \
    -H "Content-Type: application/json" \
    "https://api.bitbucket.org/2.0/repositories/${repo}/pullrequests" \
    -d "$payload")

  http_code=$(tail  -n1  <<< "$response")
  body_json=$(head  -n-1 <<< "$response")

  if [[ "$http_code" == "201" ]]; then
    if [[ -n "$JQ_BIN" ]] && "$JQ_BIN" --version >/dev/null 2>&1; then
      "$JQ_BIN" -r '.links.html.href' <<< "$body_json"
    else
      _json_pr_url "$body_json"
    fi
  elif grep -q "already exists" <<< "$body_json" 2>/dev/null; then
    log_warn "PR already open for branch $branch on $repo — skipping"
  else
    if [[ -n "$JQ_BIN" ]] && "$JQ_BIN" --version >/dev/null 2>&1; then
      log_error "Bitbucket API $http_code: $("$JQ_BIN" -r '.error.message // .' <<< "$body_json")"
    else
      log_error "Bitbucket API $http_code: $(_json_pr_error "$body_json")"
    fi
    return 1
  fi
}

# ── Interactive selection ─────────────────────────────────────────────────────

# Fetches tags from a Bitbucket repo via git ls-remote (no clone needed).
fetch_source_tags() {
  local url; url=$(_bb_url "$1")
  git ls-remote --tags "$url" 2>/dev/null \
    | grep -v '\^{}' \
    | awk '{print $2}' \
    | sed 's|refs/tags/||' \
    | { sort -Vr 2>/dev/null || sort -r; }
}

# Pre-load repo list into arrays (avoids repeated awk calls in menus).
_RNAMES=(); _RPATHS=()
for ((_i=0; _i<REPO_COUNT; _i++)); do
  _RNAMES+=("$(_cf_repo_name "$_i")")
  _RPATHS+=("$(_cf_repo_path "$_i")")
done
if [[ "${#_RNAMES[@]}" -eq 0 ]]; then
  log_error "No repos found in $CONFIG_FILE"
  exit 1
fi

# ── 1. Source repo ────────────────────────────────────────────────────────────
if [[ -z "$SOURCE_NAME" ]]; then
  if ! $_INTERACTIVE; then
    log_error "--source <name> is required (not running interactively)"
    log_error "Available: $(_cf_repo_names_csv)"
    usage; exit 1
  fi

  printf '\n### sync-deploy.sh ###\n'
  printf 'Config: %s\n\n' "$CONFIG_FILE"
  printf 'You will be asked: (1) source repo  (2) FROM tag/commit  (3) TO tag/commit  (4) target repo(s)\n\n'
  printf '--- Step 1: Select SOURCE repo ---\n'
  printf 'The diff will be computed on this repo.\n\n'
  for ((_i=0; _i<REPO_COUNT; _i++)); do
    printf '  %d) %-24s  (%s)\n' "$((_i+1))" "${_RNAMES[$_i]}" "${_RPATHS[$_i]}"
  done
  printf '\n'

  if [[ "$REPO_COUNT" -eq 1 ]]; then
    SOURCE_NAME="${_RNAMES[0]}"
    printf 'Auto-selected: %s\n\n' "$SOURCE_NAME"
  else
    _pick=""
    while true; do
      printf 'Enter number [1-%d]: ' "$REPO_COUNT"
      read -r _pick 2>/dev/null || _pick=""
      if [[ -z "$_pick" ]]; then
        SOURCE_NAME="${_RNAMES[0]}"
        printf '-> %s (default)\n\n' "$SOURCE_NAME"
        break
      fi
      if [[ "$_pick" =~ ^[0-9]+$ ]] && ((_pick >= 1 && _pick <= REPO_COUNT)); then
        SOURCE_NAME="${_RNAMES[$((_pick-1))]}"
        printf '-> %s\n\n' "$SOURCE_NAME"
        break
      fi
      printf 'Invalid — enter a number between 1 and %d.\n' "$REPO_COUNT"
    done
    unset _pick
  fi
fi

# ── 2. Ref range (FROM → TO commit/tag on the source repo) ───────────────────
if ! $FROM_EXPLICIT || ! $TO_EXPLICIT; then
  _src_path=""
  for ((_i=0; _i<REPO_COUNT; _i++)); do
    if [[ "${_RNAMES[$_i]}" == "$SOURCE_NAME" ]]; then
      _src_path="${_RPATHS[$_i]}"; break
    fi
  done

  if $_INTERACTIVE; then
    log_info "Fetching tags from ${_src_path} ..."
    _tags=()
    while IFS= read -r _t; do
      [[ -n "$_t" ]] && _tags+=("$_t")
    done < <(fetch_source_tags "$_src_path" 2>/dev/null || true)

    # _menu_ref <result_var> <title> <default_label> <default_value> [tags...]
    # Uses printf -v to assign the chosen value to the named variable.
    _menu_ref() {
      local _rv="$1" _ti="$2" _dl="$3" _dv="$4"; shift 4
      local -a _lb=("$_dl") _vl=("$_dv")
      local _x; for _x in "$@"; do _lb+=("$_x"); _vl+=("$_x"); done
      local _cnt=${#_lb[@]}
      local _show=$(( _cnt < 16 ? _cnt : 16 ))

      printf '--- %s ---\n\n' "$_ti"
      local _j
      for ((_j=0; _j<_show; _j++)); do
        printf '  %d) %s\n' "$((_j+1))" "${_lb[$_j]}"
      done
      [[ $_cnt -gt $_show ]] && printf '  ... (%d more tags not shown)\n' "$((_cnt-_show))"
      printf '\nEnter number [1-%d, ENTER=1]: ' "$_show"

      local _r
      read -r _r 2>/dev/null || _r=""
      [[ -z "$_r" ]] && _r=1
      { [[ "$_r" =~ ^[0-9]+$ ]] && ((_r >= 1 && _r <= _show)); } || _r=1
      printf -v "$_rv" '%s' "${_vl[$((_r-1))]}"
      printf '-> %s\n\n' "${_lb[$((_r-1))]}"
    }

    printf '\n'
    if ! $FROM_EXPLICIT; then
      _menu_ref FROM_REF \
        "Select FROM ref (start of diff — older commit/tag)" \
        "HEAD~1 — previous commit (default)" "HEAD~1" \
        "${_tags[@]+"${_tags[@]}"}"
    fi
    if ! $TO_EXPLICIT; then
      _menu_ref TO_REF \
        "Select TO ref (end of diff — newer commit/tag)" \
        "HEAD — latest commit (default)" "HEAD" \
        "${_tags[@]+"${_tags[@]}"}"
    fi
    unset _t _tags
  fi
  unset _src_path
fi

# ── 3. Target repos (which repos receive the diff) ────────────────────────────
if [[ "$FILTER_TARGETS" == "all" ]]; then
  _tgt_names=(); _tgt_paths=()
  for ((_i=0; _i<REPO_COUNT; _i++)); do
    [[ "${_RNAMES[$_i]}" == "$SOURCE_NAME" ]] && continue
    _tgt_names+=("${_RNAMES[$_i]}"); _tgt_paths+=("${_RPATHS[$_i]}")
  done
  _nt=${#_tgt_names[@]}

  if [[ $_nt -eq 0 ]]; then
    log_error "No target repos left after excluding source '$SOURCE_NAME'"
    exit 1
  elif [[ $_nt -eq 1 ]]; then
    FILTER_TARGETS="${_tgt_names[0]}"
    printf 'Only one target — auto-selected: %s\n\n' "${_tgt_names[0]}"
  elif $_INTERACTIVE; then
    printf '--- Select TARGET repo(s) ---\n'
    printf 'The diff (%s -> %s) will be applied to these repos.\n\n' "$FROM_REF" "$TO_REF"
    for ((_i=0; _i<_nt; _i++)); do
      printf '  %d) %-24s  (%s)\n' "$((_i+1))" "${_tgt_names[$_i]}" "${_tgt_paths[$_i]}"
    done
    printf '\nEnter numbers (space-separated), or ENTER for all: '
    read -r _picks 2>/dev/null || _picks=""

    if [[ -z "$_picks" ]]; then
      _sel=("${_tgt_names[@]}")
    else
      _sel=()
      for _p in $_picks; do
        [[ "$_p" =~ ^[0-9]+$ ]] && ((_p >= 1 && _p <= _nt)) \
          && _sel+=("${_tgt_names[$((_p-1))]}")
      done
      if [[ ${#_sel[@]} -eq 0 ]]; then
        printf 'No valid selection — using all.\n'
        _sel=("${_tgt_names[@]}")
      fi
    fi

    _oifs="$IFS"; IFS=','
    FILTER_TARGETS="${_sel[*]}"
    IFS="$_oifs"
    printf '-> %s\n\n' "$FILTER_TARGETS"
    unset _picks _p _sel _oifs
  fi
  unset _tgt_names _tgt_paths _nt
fi
unset _RNAMES _RPATHS _i

# ── Branch name: sync/deploy-from-<from>-to-<to> ─────────────────────────────
SYNC_BRANCH="sync/deploy-from-$(_sanitize_ref_for_branch "$FROM_REF")-to-$(_sanitize_ref_for_branch "$TO_REF")"

# ─────────────────────────────────────────────────────────────────────────────
# Everything below this line is the sync engine — no interactive code.
# ─────────────────────────────────────────────────────────────────────────────


# ── Resolve source repo from name ────────────────────────────────────────────
if [[ -z "$SOURCE_NAME" ]]; then
  log_error "--source <name> is required in non-interactive mode"
  exit 1
fi
_IDX=$(_cf_repo_index "$SOURCE_NAME")
if [[ "$_IDX" == "null" ]]; then
  log_error "Source repo '$SOURCE_NAME' not found in $CONFIG_FILE"
  log_error "Available: $(_cf_repo_names_csv)"
  exit 1
fi
SOURCE_REPO=$(_cf_repo_path "$_IDX")
SOURCE_SUBS=$(_cf_repo_subs "$_IDX")
unset _IDX

# ── Clone / update source ─────────────────────────────────────────────────────
log_section "Source: $SOURCE_NAME ($SOURCE_REPO)  ($FROM_REF → $TO_REF)"
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
  printf -- '- `[%s]` `%s`\n' "$s" "${f2:-$f1}"
done <<< "$CHANGED_FILES")

# ── Process each target ───────────────────────────────────────────────────────
PASS=()
FAIL=()

TARGET_COUNT=$(( REPO_COUNT - 1 ))   # for display purposes only
_TARGET_NUM=0
for i in $(seq 0 $((REPO_COUNT - 1))); do
  TARGET_NAME=$(_cf_repo_name "$i")
  TARGET_REPO=$(_cf_repo_path "$i")
  TARGET_SUBS=$(_cf_repo_subs "$i")

  is_target_included "$TARGET_NAME" || continue
  _TARGET_NUM=$(( _TARGET_NUM + 1 ))

  log_section "[$_TARGET_NUM/$TARGET_COUNT] $TARGET_NAME → $TARGET_REPO"

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
    IMAGE_NOTES=()
    CONFLICT_FILES=()

    while IFS=$'\t' read -r status file1 file2; do
      op="${status:0:1}"  # strip rename/copy similarity score (R095 → R, C090 → C)

      case "$op" in

        # ── Delete ────────────────────────────────────────────────────────────
        D)
          tgt_file=$(echo "$file1" | sed "$SED_SCRIPT")
          if [[ -f "$TARGET_DIR/$tgt_file" ]]; then
            log_info "Deleting: $tgt_file"
            git -C "$TARGET_DIR" rm -f "$tgt_file"
            HAS_CHANGES=true
          fi
          ;;

        # ── Rename ────────────────────────────────────────────────────────────
        # file1 = old path, file2 = new path (both in source naming)
        R)
          tgt_file1=$(echo "$file1" | sed "$SED_SCRIPT")
          tgt_file2=$(echo "$file2" | sed "$SED_SCRIPT")
          orig=$(mktemp "$WORK_DIR/.orig_XXXXXX")
          has_orig=false
          if [[ -f "$TARGET_DIR/$tgt_file1" ]]; then
            cp "$TARGET_DIR/$tgt_file1" "$orig"
            has_orig=true
            git -C "$TARGET_DIR" rm -f "$tgt_file1"
          fi

          mkdir -p "$(dirname "$TARGET_DIR/$tgt_file2")"

          if is_sealed_secret "$SOURCE_DIR/$file2"; then
            if $has_orig && is_sealed_secret "$orig"; then
              cp "$orig" "$TARGET_DIR/$tgt_file2"
              apply_subs "$TARGET_DIR/$tgt_file2" "$SED_SCRIPT"
              SEALED_NOTES+=("- \`[RENAMED]\` \`$tgt_file1\` → \`$tgt_file2\` — target's own encrypted values moved to new path")
            else
              copy_and_apply "$file2" "$tgt_file2" "$TARGET_DIR" "$SED_SCRIPT" || true
              [[ -f "$TARGET_DIR/$tgt_file2" ]] && strip_encrypted_data "$TARGET_DIR/$tgt_file2"
              SEALED_NOTES+=("- \`[RENAMED]\` \`$tgt_file1\` → \`$tgt_file2\` — encryptedData blanked, re-seal for this cluster")
            fi
          else
            copy_and_apply "$file2" "$tgt_file2" "$TARGET_DIR" "$SED_SCRIPT"
            $has_orig && restore_image_lines "$TARGET_DIR/$tgt_file2" "$orig"
            if has_image_lines "$TARGET_DIR/$tgt_file2"; then
              IMAGE_NOTES+=("- \`[RENAMED]\` \`$tgt_file2\` — image tags kept from \`$tgt_file1\`")
            fi
          fi

          git -C "$TARGET_DIR" add "$tgt_file2"
          HAS_CHANGES=true
          rm -f "$orig"
          ;;

        # ── Modify ────────────────────────────────────────────────────────────
        M)
          tgt_file=$(echo "$file1" | sed "$SED_SCRIPT")
          if is_sealed_secret "$SOURCE_DIR/$file1"; then
            SEALED_NOTES+=("- \`[MODIFIED]\` \`$tgt_file\` — **not synced** (cluster-specific encryption); re-seal manually if the value changed")
          else
            merge_rc=0
            three_way_merge_file "$file1" "$tgt_file" "$TARGET_DIR" "$SED_SCRIPT" || merge_rc=$?
            [[ $merge_rc -eq 1 ]] && CONFLICT_FILES+=("$tgt_file")
            if has_image_lines "$TARGET_DIR/$tgt_file"; then
              IMAGE_NOTES+=("- \`[MODIFIED]\` \`$tgt_file\` — image tags preserved from target")
            fi
            git -C "$TARGET_DIR" add "$tgt_file"
            HAS_CHANGES=true
          fi
          ;;

        # ── Add / Copy ────────────────────────────────────────────────────────
        # For git C (copy): file1=original path, file2=new path. Use file2 as dest.
        # For git A (add): file1 is the only path.
        # For git C (copy): file1=original path, file2=new path. Use file2 as dest.
        # For git A (add): file1 is the only path.
        A|C|*)
          src_new_file="${file2:-$file1}"
          tgt_new_file=$(echo "$src_new_file" | sed "$SED_SCRIPT")

          if is_sealed_secret "$SOURCE_DIR/$src_new_file"; then
            src_name=$(get_sealed_secret_name "$SOURCE_DIR/$src_new_file")

            # Determine if this is a copy of an existing sealed secret (same
            # metadata.name already exists elsewhere in the source repo) or truly new.
            src_other=$(find_sealed_secret_by_name \
              "$src_name" "$SOURCE_DIR" "$SOURCE_DIR/$src_new_file" || true)

            mkdir -p "$(dirname "$TARGET_DIR/$tgt_new_file")"

            if [[ -n "$src_other" ]]; then
              tgt_name=$(echo "$src_name" | sed "$SED_SCRIPT")
              tgt_existing=$(find_sealed_secret_by_name "$tgt_name" "$TARGET_DIR" || true)

              if [[ -n "$tgt_existing" ]]; then
                cp "$tgt_existing" "$TARGET_DIR/$tgt_new_file"
                apply_subs "$TARGET_DIR/$tgt_new_file" "$SED_SCRIPT"
                SEALED_NOTES+=("- \`[COPIED]\` \`$tgt_new_file\` — target's own sealed secret copied from \`${tgt_existing#"$TARGET_DIR/"}\` (encrypted values preserved)")
              else
                copy_and_apply "$src_new_file" "$tgt_new_file" "$TARGET_DIR" "$SED_SCRIPT"
                strip_encrypted_data "$TARGET_DIR/$tgt_new_file"
                SEALED_NOTES+=("- \`[COPIED]\` \`$tgt_new_file\` — no matching secret found in target; encryptedData blanked, re-seal for this cluster")
              fi
            else
              copy_and_apply "$src_new_file" "$tgt_new_file" "$TARGET_DIR" "$SED_SCRIPT"
              strip_encrypted_data "$TARGET_DIR/$tgt_new_file"
              SEALED_NOTES+=("- \`[ADDED]\` \`$tgt_new_file\` — new secret; encryptedData blanked, re-seal for this cluster")
            fi

            git -C "$TARGET_DIR" add "$tgt_new_file"
            HAS_CHANGES=true

          else
            if copy_and_apply "$src_new_file" "$tgt_new_file" "$TARGET_DIR" "$SED_SCRIPT"; then
              if has_image_lines "$TARGET_DIR/$tgt_new_file"; then
                IMAGE_NOTES+=("- \`[ADDED]\` \`$tgt_new_file\` — new file; image tags copied from source (update if needed)")
              fi
              git -C "$TARGET_DIR" add "$tgt_new_file"
              HAS_CHANGES=true
            fi
          fi
          ;;

      esac
    done <<< "$CHANGED_FILES"

    if ! $HAS_CHANGES; then
      if [[ ${#SEALED_NOTES[@]} -gt 0 ]]; then
        log_warn "$TARGET_NAME: only sealed secret changes (no commit needed)"
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

    # ── Build PR body ─────────────────────────────────────────────────────────
    SEALED_SECTION=""
    if [[ ${#SEALED_NOTES[@]} -gt 0 ]]; then
      SEALED_SECTION="

### ⚠️ Sealed Secrets — manual action required

$(printf '%s\n' "${SEALED_NOTES[@]}")

Run \`kubeseal\` to encrypt values for this cluster before merging."
    fi

    IMAGE_SECTION=""
    if [[ ${#IMAGE_NOTES[@]} -gt 0 ]]; then
      IMAGE_SECTION="

### 🏷️ Image tags

$(printf '%s\n' "${IMAGE_NOTES[@]}")

Image tags are environment-specific and were not copied from source."
    fi

    CONFLICT_SECTION=""
    if [[ ${#CONFLICT_FILES[@]} -gt 0 ]]; then
      CONFLICT_SECTION="

### ⚡ Merge conflicts — resolve before merging

$(printf -- '- `%s`\n' "${CONFLICT_FILES[@]}")

These files contain \`<<<<<<<\` conflict markers. Edit them to resolve, then commit."
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
${CHANGED_FILES_MD}${SEALED_SECTION}${IMAGE_SECTION}${CONFLICT_SECTION}

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
