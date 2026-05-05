#!/usr/bin/env bash
# sync-deploy.sh — sync OpenShift deploy-repo diffs across Bitbucket repos
#
# IMPORTANT: must be run with bash, not sh.
#   Correct:   bash sync-deploy.sh
#   Wrong:     sh sync-deploy.sh

# Guard: abort immediately if running under sh/dash instead of bash.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: this script requires bash. Run it as:" >&2
  echo "  bash $0 $*" >&2
  exit 1
fi
#
# Per-file rules
#   D  deleted   → delete from target
#   M  modified  → three-way merge
#                  SealedSecret: skip (cluster-specific ciphers; re-seal manually)
#   A  added     → copy + name-substitution
#                  SealedSecret: if same metadata.name found elsewhere in source
#                    → copy target's own matching secret to new path
#                  SealedSecret: truly new (no match elsewhere in source)
#                    → blank encryptedData (TODO: kubeseal)
#   R  renamed   → remove old path, create new path
#                  SealedSecret: move target's own secret to new path;
#                    if not found → blank encryptedData
#   C  copied    → treated same as A
#
#   Image-tag YAML keys (image / imageTag / tag / newTag / newName / digest) are
#   NEVER taken from source for files that already exist in the target.
#   New files keep source values and are flagged in the PR description.
#
#   Protected ConfigMap keys always keep the target's existing value in a merge.

set -euo pipefail
trap 'printf "[FATAL] aborted at line %d\n" "$LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/repos.json"
WORK_DIR="$SCRIPT_DIR/.work"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ── colour output ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
if [[ -n "${MSYSTEM:-}" || -n "${WINDIR:-}" ]]; then
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log_info()    { printf "${GREEN}[INFO]${NC}  %s\n"  "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n"   "$*" >&2; }
log_section() { printf "\n${BLUE}==> %s${NC}\n"    "$*"; }

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: sync-deploy.sh [OPTIONS]

Syncs deploy-repo changes to all configured Bitbucket repos, applying per-repo
name substitutions, preserving image tags, and handling Sealed Secrets.

Options:
  --source <name>    Source repo name (from repos list)
  --from <ref>       Start ref — tag or commit  (default: HEAD~1)
  --to <ref>         End ref   — tag or commit  (default: HEAD)
  --targets <names>  Comma-separated target names, or "all" (default: all)
  --dry-run          Show what would happen — no clones, pushes, or PRs
  --config <file>    Path to repos.json         (default: ./repos.json)
  -h, --help         Show this help

Environment:
  BITBUCKET_USER   Bitbucket username       (optional — if set together with TOKEN,
  BITBUCKET_TOKEN  Bitbucket app password    uses HTTPS; otherwise uses SSH)

Examples:
  sync-deploy.sh
  sync-deploy.sh --source source-deploy --from v1.2.0 --to v1.3.0
  sync-deploy.sh --source app-a --targets app-b,app-c --dry-run
EOF
}

# ── argument parsing ──────────────────────────────────────────────────────────
SOURCE_NAME=""
FROM_REF="HEAD~1"
TO_REF="HEAD"
FROM_EXPLICIT=false
TO_EXPLICIT=false
FILTER_TARGETS="all"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --source)  SOURCE_NAME="$2"; shift 2 ;;
    --from)    FROM_REF="$2"; FROM_EXPLICIT=true; shift 2 ;;
    --to)      TO_REF="$2";   TO_EXPLICIT=true;   shift 2 ;;
    --targets) FILTER_TARGETS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true;  shift   ;;
    --config)  CONFIG_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0  ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── prerequisites ─────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || { log_error "Config not found: $CONFIG_FILE"; exit 1; }
for _c in git curl awk; do
  command -v "$_c" >/dev/null || { log_error "Required tool not found: $_c"; exit 1; }
done
unset _c

# True when a real user is at the keyboard
_INTERACTIVE=false
[[ -t 0 || -n "${MSYSTEM:-}" ]] && _INTERACTIVE=true

# ── pure-awk JSON / config helpers ────────────────────────────────────────────

# Top-level string value from repos.json: { "key": "value" }
_cf_str() {
  awk -F'"' -v k="$1" '$2==k && NF>=4 { print $4; exit }' "$CONFIG_FILE"
}

# Count repo entries (by counting "name" keys)
_cf_repo_count() {
  awk -F'"' '$2=="name" && NF>=4 { c++ } END { print c+0 }' "$CONFIG_FILE"
}

# 0-based name / path accessors
_cf_repo_name() {
  awk -F'"' -v idx="$1" \
    '$2=="name" && NF>=4 { if (c++==idx) { print $4; exit } }' "$CONFIG_FILE"
}
_cf_repo_path() {
  awk -F'"' -v idx="$1" \
    '$2=="repo" && NF>=4 { if (c++==idx) { print $4; exit } }' "$CONFIG_FILE"
}

# Returns the 0-based index of a repo by name, or "null" if not found
_cf_repo_index() {
  awk -F'"' -v name="$1" '
    $2=="name" && NF>=4 {
      if ($4==name) { print c+0; found=1; exit }
      c++
    }
    END { if (!found) print "null" }
  ' "$CONFIG_FILE"
}

_cf_repo_names_csv() {
  awk -F'"' \
    '$2=="name" && NF>=4 { printf "%s%s", (sep?", ":""), $4; sep=1 }
     END { print "" }' "$CONFIG_FILE"
}

# Returns KEY<TAB>VALUE lines for the substitutions block of repo at index idx
_cf_repo_subs() {
  awk -F'"' -v idx="$1" '
    $2=="name" && NF>=4              { nc++ }
    nc==idx+1 && $2=="substitutions" { in_s=1; next }
    in_s && /^[[:space:]]*\}/        { exit }
    in_s && NF>=4 && $2!="" && $3~/^:/ { print $2 "\t" $4 }
  ' "$CONFIG_FILE"
}

# Returns pipe-delimited alternation of protected ConfigMap key names
# (handles both single-line and multi-line JSON arrays)
_cf_protected_keys() {
  awk '
    /"protected_configmap_keys"/ {
      in_a=1
      rest=$0; sub(/^[^[]*\[/, "", rest)
      while (1) {
        i=index(rest,"\""); if (!i) break; rest=substr(rest,i+1)
        j=index(rest,"\""); if (!j) break
        printf "%s%s", (sep?"|":""), substr(rest,1,j-1); sep=1
        rest=substr(rest,j+1)
      }
      if (index($0,"]")) { in_a=0; if (sep) printf "\n" }
      next
    }
    in_a && /\]/ { if (sep) printf "\n"; exit }
    in_a {
      i=index($0,"\""); if (!i) next; rest=substr($0,i+1)
      j=index(rest,"\""); if (!j) next
      printf "%s%s", (sep?"|":""), substr(rest,1,j-1); sep=1
    }
  ' "$CONFIG_FILE"
}

# JSON-encode a string value (escapes \, ", and control characters)
_json_str() {
  printf '%s' "$1" | awk '{
    gsub(/\\/, "\\\\")
    gsub(/"/, "\\\"")
    gsub(/\r/, "\\r")
    gsub(/\t/, "\\t")
    printf "%s%s", (NR>1 ? "\\n" : ""), $0
  }'
}

# Build Bitbucket PR creation payload
_pr_payload() {
  # args: title body branch base_branch
  printf '{"title":"%s","description":"%s","source":{"branch":{"name":"%s"}},"destination":{"branch":{"name":"%s"}},"close_source_branch":true}' \
    "$(_json_str "$1")" "$(_json_str "$2")" "$(_json_str "$3")" "$(_json_str "$4")"
}

# Extract HTML href from Bitbucket API response JSON
_pr_html_url() {
  printf '%s' "$1" | tr -d '\n\r' \
    | grep -o '"html":[[:space:]]*{"href":"[^"]*"' | head -1 \
    | grep -o '"href":"[^"]*"' | cut -d'"' -f4
}

# Extract error message from Bitbucket API error response
_pr_error_msg() {
  printf '%s' "$1" | tr -d '\n\r' \
    | grep -o '"message":"[^"]*"' | head -1 \
    | cut -d'"' -f4
}

# Sanitise a git ref so it is safe as a branch-name component
_sanitize_ref() {
  printf '%s' "$1" \
    | sed 's/[[:space:]~^:?*\[\\]/-/g; s/\.\./-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

# ── git helpers ───────────────────────────────────────────────────────────────

# Build a Bitbucket clone URL.
# Uses SSH by default (git@bitbucket.org:workspace/repo.git) so that the
# existing SSH key in the git credential store is used automatically.
# Falls back to HTTPS only when BITBUCKET_USER and BITBUCKET_TOKEN are both set.
_bb_url() {
  if [[ -n "${BITBUCKET_USER:-}" && -n "${BITBUCKET_TOKEN:-}" ]]; then
    printf 'https://%s:%s@bitbucket.org/%s.git' \
      "$BITBUCKET_USER" "$BITBUCKET_TOKEN" "$1"
  else
    printf 'git@bitbucket.org:%s.git' "$1"
  fi
}

# Clone repo or reset an existing clone to origin/<BASE_BRANCH>
clone_or_update() {
  local repo="$1" dir="$2"
  local url; url=$(_bb_url "$repo")
  if [[ -d "$dir/.git" ]]; then
    log_info "Fetching $repo"
    git -C "$dir" remote set-url origin "$url"
    git -C "$dir" fetch origin
    git -C "$dir" checkout "$BASE_BRANCH"
    git -C "$dir" reset --hard "origin/$BASE_BRANCH"
  else
    log_info "Cloning $repo"
    git clone "$url" "$dir"
  fi
  git -C "$dir" config user.email \
    "$(git config --global user.email 2>/dev/null || printf 'sync-deploy@automation')"
  git -C "$dir" config user.name \
    "$(git config --global user.name  2>/dev/null || printf 'Deploy Sync Bot')"
}

# Fetch tag names from a remote without cloning (for interactive menus)
_fetch_tags() {
  git ls-remote --tags "$(_bb_url "$1")" 2>/dev/null \
    | grep -v '\^{}' \
    | awk '{print $2}' \
    | sed 's|refs/tags/||' \
    | { sort -Vr 2>/dev/null || sort -r; }
}

# ── file-processing helpers ───────────────────────────────────────────────────

is_text_file()     { grep -qI '' "$1" 2>/dev/null; }
is_sealed_secret() {
  is_text_file "$1" && grep -q 'kind:[[:space:]]*SealedSecret' "$1" 2>/dev/null
}

# Extract the metadata.name value from a SealedSecret YAML file
get_sealed_secret_name() {
  awk '/^metadata:/{m=1;next} m && /^  name:/{print $2;exit} /^[a-zA-Z]/{m=0}' "$1"
}

# Find the first SealedSecret file in dir with the given metadata.name.
# Optional $3: absolute path to exclude (to skip the file itself).
find_sealed_secret_by_name() {
  local name="$1" dir="$2" exclude="${3:-}"
  while IFS= read -r -d '' f; do
    [[ -n "$exclude" && "$f" == "$exclude" ]] && continue
    is_sealed_secret "$f" || continue
    [[ "$(get_sealed_secret_name "$f")" == "$name" ]] && printf '%s\n' "$f" && return 0
  done < <(find "$dir" \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
  return 1
}

# Replace every value under spec.encryptedData with a TODO kubeseal marker
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

# True when file contains any image-related YAML key
has_image_lines() {
  grep -qE '^[[:space:]]*(image|imageTag|tag|newTag|newName|digest):[[:space:]]' \
    "$1" 2>/dev/null
}

# ── name-substitution helpers ─────────────────────────────────────────────────

# Build a sed substitution script from source → target subs.
# Sorted longest-source-value first to prevent partial-string clobbering.
# Both arguments are KEY<TAB>VALUE lines (from _cf_repo_subs).
build_sed_script() {
  local src_subs="$1" tgt_subs="$2"
  local src_f tgt_f
  src_f=$(mktemp "${TMPDIR:-/tmp}/.subs_src_XXXXXX")
  tgt_f=$(mktemp "${TMPDIR:-/tmp}/.subs_tgt_XXXXXX")
  printf '%s\n' "$src_subs" > "$src_f"
  printf '%s\n' "$tgt_subs" > "$tgt_f"

  local sed_script=""
  while IFS=$'\t' read -r sv tv; do
    [[ -z "$sv" || -z "$tv" ]] && continue
    local src_esc tgt_esc
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
      for (i=1; i<cnt; i++) {
        sv2=svals[i]; tv2=tvals[i]; l2=lens[i]; j=i-1
        while (j>=0 && lens[j]<l2) {
          svals[j+1]=svals[j]; tvals[j+1]=tvals[j]; lens[j+1]=lens[j]; j--
        }
        svals[j+1]=sv2; tvals[j+1]=tv2; lens[j+1]=l2
      }
      for (i=0; i<cnt; i++) print svals[i] "\t" tvals[i]
    }
  ' "$src_f" "$tgt_f")

  rm -f "$src_f" "$tgt_f"
  printf '%s' "$sed_script"
}

# Apply sed substitutions to a file in-place; skip binary files
apply_subs() {
  local file="$1" sed_script="$2"
  [[ -z "$sed_script" ]] && return 0
  is_text_file "$file" || { log_warn "Binary file skipped: $(basename "$file")"; return 0; }
  sed -i "$sed_script" "$file"
}

# Apply substitution script to a path string (handles empty script safely)
_sub_path() {
  if [[ -z "$SED_SCRIPT" ]]; then
    printf '%s' "$1"
  else
    printf '%s' "$1" | sed "$SED_SCRIPT"
  fi
}

# Copy src_rel from SOURCE_DIR to tgt_dir/tgt_rel, then apply name subs.
# Returns 1 (non-fatal) when the source file is absent.
copy_and_apply() {
  local src_rel="$1" tgt_rel="$2" tgt_dir="$3" sed_script="$4"
  local src_abs="$SOURCE_DIR/$src_rel"
  if [[ ! -f "$src_abs" ]]; then
    log_warn "Source file missing: $src_rel — skipping"
    return 1
  fi
  mkdir -p "$(dirname "$tgt_dir/$tgt_rel")"
  cp "$src_abs" "$tgt_dir/$tgt_rel"
  apply_subs "$tgt_dir/$tgt_rel" "$sed_script"
}

# Restore image-related YAML lines in FILE from ORIGINAL.
# Prevents source image tags from overwriting target values.
# Matches by YAML key + indentation level (handles multi-container pods).
restore_image_lines() {
  local file="$1" original="$2"
  [[ -f "$original" ]] || return 0
  is_text_file "$file"  || return 0
  awk '
    NR==FNR {
      if (/^[[:space:]]*(image|imageTag|tag|newTag|newName|digest):[[:space:]]/) {
        key=$0; sub(/:[[:space:]].*$/, "", key)
        kc[key]++; kl[key,kc[key]]=$0
      }
      next
    }
    /^[[:space:]]*(image|imageTag|tag|newTag|newName|digest):[[:space:]]/ {
      key=$0; sub(/:[[:space:]].*$/, "", key)
      ku[key]++
      if (ku[key] <= kc[key]) { print kl[key,ku[key]]; next }
    }
    { print }
  ' "$original" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# In THEIRS, replace protected ConfigMap values with TARGET's existing values,
# so git merge-file sees "no change" and always keeps the target's value.
# Keys absent from target pass through unchanged (first-time copy keeps source).
neutralize_configmap_keys() {
  local theirs="$1" target="$2"
  [[ -z "${PROTECTED_CM_KEYS:-}" ]] && return 0
  grep -q 'kind:[[:space:]]*ConfigMap' "$theirs" 2>/dev/null || return 0
  [[ -f "$target" ]] || return 0
  is_text_file "$theirs" || return 0
  awk -v pat="$PROTECTED_CM_KEYS" '
    BEGIN { full_pat = "^[[:space:]]+(" pat "):[[:space:]]" }
    NR==FNR {
      if ($0 ~ full_pat) {
        key=$0; sub(/:[[:space:]].*$/, "", key); gsub(/^[[:space:]]+/, "", key)
        tgt_val[key]=$0
      }
      next
    }
    $0 ~ full_pat {
      key=$0; sub(/:[[:space:]].*$/, "", key); gsub(/^[[:space:]]+/, "", key)
      if (key in tgt_val) { print tgt_val[key]; next }
    }
    { print }
  ' "$target" "$theirs" > "$theirs.tmp" && mv "$theirs.tmp" "$theirs"
}

# Three-way merge a modified file into the target repo.
#
# base   = source file at FROM_REF with substitutions applied
# theirs = source file at TO_REF   with substitutions applied
# ours   = current target file (written in-place by git merge-file)
#
# For existing target files: image-tag lines and protected ConfigMap values
# in THEIRS are replaced with BASE values before merging, so git merge-file
# always keeps the target's own values.  Conflicts get markers written.
#
# For new files (no target yet): THEIRS is written directly (first-time copy).
#
# Returns: 0=clean merge, 1=conflict markers written, 2+=hard error
three_way_merge_file() {
  local src_path="$1" tgt_path="$2" tgt_dir="$3" sed_script="$4"
  local src_abs="$SOURCE_DIR/$src_path"
  local tgt_abs="$tgt_dir/$tgt_path"

  local base theirs
  base=$(mktemp   "$WORK_DIR/.3wm_base_XXXXXX")
  theirs=$(mktemp "$WORK_DIR/.3wm_theirs_XXXXXX")

  # base: source at FROM_REF; fall back to simple copy if file is brand-new
  if ! git -C "$SOURCE_DIR" show "${FROM_REF}:${src_path}" > "$base" 2>/dev/null; then
    rm -f "$base" "$theirs"
    copy_and_apply "$src_path" "$tgt_path" "$tgt_dir" "$sed_script"
    return $?
  fi
  apply_subs "$base" "$sed_script"

  # theirs: source at TO_REF
  cp "$src_abs" "$theirs"
  apply_subs "$theirs" "$sed_script"

  # First-time copy: no target exists yet — write theirs directly
  if [[ ! -f "$tgt_abs" ]]; then
    mkdir -p "$(dirname "$tgt_abs")"
    cp "$theirs" "$tgt_abs"
    rm -f "$base" "$theirs"
    return 0
  fi

  # Existing file: neutralise env-specific lines so merge keeps target values
  restore_image_lines       "$theirs" "$base"
  neutralize_configmap_keys "$theirs" "$tgt_abs"

  local rc=0
  git merge-file \
    -L "target (ours)" \
    -L "base (${FROM_REF})" \
    -L "source (${TO_REF})" \
    "$tgt_abs" "$base" "$theirs" || rc=$?
  rm -f "$base" "$theirs"

  if   [[ $rc -eq 1 ]]; then return 1
  elif [[ $rc -gt 1 ]]; then log_error "git merge-file error ($rc): $tgt_path"; return 2
  fi
}

# ── Bitbucket PR creation ─────────────────────────────────────────────────────
create_bitbucket_pr() {
  local repo="$1" branch="$2" title="$3" body="$4"

  local payload
  payload=$(_pr_payload "$title" "$body" "$branch" "$BASE_BRANCH")

  # Credentials: prefer env vars, fall back to git credential helper
  local api_user="${BITBUCKET_USER:-}"
  local api_token="${BITBUCKET_TOKEN:-}"
  if [[ -z "$api_user" || -z "$api_token" ]]; then
    local _cred
    _cred=$(printf 'protocol=https\nhost=bitbucket.org\n' \
              | git credential fill 2>/dev/null) || true
    [[ -z "$api_user"  ]] && api_user=$(printf  '%s' "$_cred" | awk -F= '/^username=/{print $2}')
    [[ -z "$api_token" ]] && api_token=$(printf '%s' "$_cred" | awk -F= '/^password=/{print $2}')
  fi

  local curl_auth=()
  [[ -n "$api_user" && -n "$api_token" ]] && curl_auth=(-u "${api_user}:${api_token}")

  local response http_code body_json
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "${curl_auth[@]+"${curl_auth[@]}"}" \
    -H "Content-Type: application/json" \
    "https://api.bitbucket.org/2.0/repositories/${repo}/pullrequests" \
    -d "$payload")

  http_code=$(tail  -n1  <<< "$response")
  body_json=$(head  -n-1 <<< "$response")

  if [[ "$http_code" == "201" ]]; then
    _pr_html_url "$body_json"
  elif grep -q "already exists" <<< "$body_json" 2>/dev/null; then
    log_warn "PR already open for branch $branch on $repo — skipping"
  else
    log_error "Bitbucket API $http_code: $(_pr_error_msg "$body_json")"
    return 1
  fi
}

# ── is this target included in the run? ───────────────────────────────────────
is_target_included() {
  [[ "$1" == "$SOURCE_NAME" ]] && return 1
  [[ "$FILTER_TARGETS" == "all" ]] && return 0
  local t; IFS=',' read -ra _arr <<< "$FILTER_TARGETS"
  for t in "${_arr[@]}"; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

# ── load static config values ─────────────────────────────────────────────────
BASE_BRANCH=$(_cf_str base_branch);      BASE_BRANCH="${BASE_BRANCH:-main}"
PR_TITLE_PREFIX=$(_cf_str title_prefix); PR_TITLE_PREFIX="${PR_TITLE_PREFIX:-chore(sync): }"
REPO_COUNT=$(_cf_repo_count)
PROTECTED_CM_KEYS=$(_cf_protected_keys)

[[ "$REPO_COUNT" -gt 0 ]] || { log_error "No repos found in $CONFIG_FILE"; exit 1; }

mkdir -p "$WORK_DIR"

# Pre-load repo list to avoid repeated awk calls in menus
_RNAMES=(); _RPATHS=()
for ((_i=0; _i<REPO_COUNT; _i++)); do
  _RNAMES+=("$(_cf_repo_name "$_i")")
  _RPATHS+=("$(_cf_repo_path "$_i")")
done

# ── Interactive step 1: source repo ──────────────────────────────────────────
if [[ -z "$SOURCE_NAME" ]]; then
  if ! $_INTERACTIVE; then
    log_error "--source is required in non-interactive mode"
    log_error "Available repos: $(_cf_repo_names_csv)"
    usage; exit 1
  fi

  echo ""
  echo "### sync-deploy.sh ###"
  echo "Config: $CONFIG_FILE"
  echo ""
  echo "Steps: (1) source repo  (2) FROM ref  (3) TO ref  (4) target(s)"
  echo ""
  echo "--- Step 1: Select SOURCE repo ---"
  echo "The diff will be computed on this repo."
  echo ""
  for ((_i=0; _i<REPO_COUNT; _i++)); do
    printf '  %d) %-24s  (%s)\n' "$((_i+1))" "${_RNAMES[$_i]}" "${_RPATHS[$_i]}"
  done
  echo ""

  if [[ "$REPO_COUNT" -eq 1 ]]; then
    SOURCE_NAME="${_RNAMES[0]}"
    echo "Only one repo — auto-selected: $SOURCE_NAME"
    echo ""
  else
    while true; do
      printf 'Enter number [1-%d, ENTER=1]: ' "$REPO_COUNT"
      read -r _pick 2>/dev/null || _pick=""
      [[ -z "$_pick" ]] && _pick=1
      if [[ "$_pick" =~ ^[0-9]+$ ]] && ((_pick >= 1 && _pick <= REPO_COUNT)); then
        SOURCE_NAME="${_RNAMES[$((_pick-1))]}"
        echo "-> $SOURCE_NAME"
        echo ""
        break
      fi
      printf 'Enter a number between 1 and %d.\n' "$REPO_COUNT"
    done
    unset _pick
  fi
fi

# ── Interactive step 2: FROM and TO refs ─────────────────────────────────────
if ! $FROM_EXPLICIT || ! $TO_EXPLICIT; then
  if $_INTERACTIVE; then
    _src_path=""
    for ((_i=0; _i<REPO_COUNT; _i++)); do
      [[ "${_RNAMES[$_i]}" == "$SOURCE_NAME" ]] && { _src_path="${_RPATHS[$_i]}"; break; }
    done

    log_info "Fetching tags from ${_src_path} ..."
    _tags=()
    while IFS= read -r _t; do [[ -n "$_t" ]] && _tags+=("$_t"); done \
      < <(_fetch_tags "$_src_path" 2>/dev/null || true)

    # _pick_ref VARNAME TITLE DEFAULT_LABEL DEFAULT_VALUE [tags…]
    _pick_ref() {
      local _rv="$1" _title="$2" _dlabel="$3" _dval="$4"; shift 4
      local -a _labels=("$_dlabel") _values=("$_dval")
      local _x; for _x in "$@"; do _labels+=("$_x"); _values+=("$_x"); done
      local _n=${#_labels[@]}
      local _show=$(( _n < 16 ? _n : 16 ))

      echo "--- $_title ---"
      echo ""
      local _j
      for ((_j=0; _j<_show; _j++)); do
        printf '  %d) %s\n' "$((_j+1))" "${_labels[$_j]}"
      done
      [[ $_n -gt $_show ]] && printf '  ... (%d more tags not listed)\n' "$((_n-_show))"
      printf '\nEnter number [1-%d, ENTER=1]: ' "$_show"

      local _r; read -r _r 2>/dev/null || _r=""
      [[ -z "$_r" ]] && _r=1
      { [[ "$_r" =~ ^[0-9]+$ ]] && ((_r>=1 && _r<=_show)); } || _r=1
      printf -v "$_rv" '%s' "${_values[$((_r-1))]}"
      echo "-> ${_labels[$((_r-1))]}"
      echo ""
    }

    printf '\n'
    $FROM_EXPLICIT || _pick_ref FROM_REF \
      "Step 2a: FROM ref (start of diff — older tag/commit)" \
      "HEAD~1 — previous commit (default)" "HEAD~1" \
      "${_tags[@]+"${_tags[@]}"}"
    $TO_EXPLICIT   || _pick_ref TO_REF \
      "Step 2b: TO ref (end of diff — newer tag/commit)" \
      "HEAD — latest commit (default)" "HEAD" \
      "${_tags[@]+"${_tags[@]}"}"
    unset _t _tags _src_path
  fi
fi

# ── Interactive step 3: target repos ─────────────────────────────────────────
if [[ "$FILTER_TARGETS" == "all" ]]; then
  _tgt_names=(); _tgt_paths=()
  for ((_i=0; _i<REPO_COUNT; _i++)); do
    [[ "${_RNAMES[$_i]}" == "$SOURCE_NAME" ]] && continue
    _tgt_names+=("${_RNAMES[$_i]}")
    _tgt_paths+=("${_RPATHS[$_i]}")
  done
  _nt=${#_tgt_names[@]}

  if [[ $_nt -eq 0 ]]; then
    log_error "No target repos after excluding source '$SOURCE_NAME'"
    exit 1
  elif [[ $_nt -eq 1 ]]; then
    FILTER_TARGETS="${_tgt_names[0]}"
    echo "Only one target — auto-selected: ${_tgt_names[0]}"
    echo ""
  elif $_INTERACTIVE; then
    echo "--- Step 3: Select TARGET repo(s) ---"
    echo "The diff ($FROM_REF -> $TO_REF) will be applied to these repos."
    echo ""
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
        [[ "$_p" =~ ^[0-9]+$ ]] && ((_p>=1 && _p<=_nt)) && _sel+=("${_tgt_names[$((_p-1))]}")
      done
      [[ ${#_sel[@]} -eq 0 ]] && { echo "Invalid — using all."; _sel=("${_tgt_names[@]}"); }
    fi

    _oifs="$IFS"; IFS=','
    FILTER_TARGETS="${_sel[*]}"
    IFS="$_oifs"
    echo "-> $FILTER_TARGETS"
    echo ""
    unset _picks _p _sel _oifs
  fi
  unset _tgt_names _tgt_paths _nt
fi
unset _RNAMES _RPATHS _i

# ── Compute branch name ───────────────────────────────────────────────────────
SYNC_BRANCH="sync/deploy-from-$(_sanitize_ref "$FROM_REF")-to-$(_sanitize_ref "$TO_REF")"

# ═════════════════════════════════════════════════════════════════════════════
# Sync engine — no interactive code below this line
# ═════════════════════════════════════════════════════════════════════════════

[[ -n "$SOURCE_NAME" ]] || { log_error "--source is required"; exit 1; }

_src_idx=$(_cf_repo_index "$SOURCE_NAME")
if [[ "$_src_idx" == "null" ]]; then
  log_error "Source repo '$SOURCE_NAME' not found in $CONFIG_FILE"
  log_error "Available: $(_cf_repo_names_csv)"
  exit 1
fi
SOURCE_REPO=$(_cf_repo_path "$_src_idx")
SOURCE_SUBS=$(_cf_repo_subs "$_src_idx")
unset _src_idx

log_section "Source: $SOURCE_NAME  ($SOURCE_REPO)  [$FROM_REF → $TO_REF]"
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
  printf '  [%s] %s\n' "$status" "${f2:-$f1}"
done <<< "$CHANGED_FILES"

CHANGED_FILES_MD=$(
  while IFS=$'\t' read -r s f1 f2; do
    printf '%s\n' "- \`[$s]\` \`${f2:-$f1}\`"
  done <<< "$CHANGED_FILES"
)

# ── Process each target repo ──────────────────────────────────────────────────
PASS=(); FAIL=()
_tgt_num=0

for ((_ti=0; _ti<REPO_COUNT; _ti++)); do
  TARGET_NAME=$(_cf_repo_name "$_ti")
  TARGET_REPO=$(_cf_repo_path "$_ti")
  TARGET_SUBS=$(_cf_repo_subs  "$_ti")

  is_target_included "$TARGET_NAME" || continue
  _tgt_num=$(( _tgt_num + 1 ))

  log_section "Target [$_tgt_num]: $TARGET_NAME → $TARGET_REPO"

  if $DRY_RUN; then
    SED_SCRIPT=$(build_sed_script "$SOURCE_SUBS" "$TARGET_SUBS")
    log_info "[DRY RUN] Branch        : $SYNC_BRANCH"
    log_info "[DRY RUN] Substitutions : ${SED_SCRIPT:-(none)}"
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
      op="${status:0:1}"  # strip similarity score: R095 → R, C090 → C

      case "$op" in

        # ── Deleted ───────────────────────────────────────────────────────────
        D)
          tgt_file=$(_sub_path "$file1")
          if [[ -f "$TARGET_DIR/$tgt_file" ]]; then
            log_info "D $tgt_file"
            git -C "$TARGET_DIR" rm -f "$tgt_file"
            HAS_CHANGES=true
          fi
          ;;

        # ── Renamed ───────────────────────────────────────────────────────────
        R)
          tgt_file1=$(_sub_path "$file1")
          tgt_file2=$(_sub_path "$file2")
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
              SEALED_NOTES+=("- \`[RENAMED]\` \`$tgt_file1\` → \`$tgt_file2\` — target's encrypted values moved to new path")
            else
              copy_and_apply "$file2" "$tgt_file2" "$TARGET_DIR" "$SED_SCRIPT" || true
              [[ -f "$TARGET_DIR/$tgt_file2" ]] && strip_encrypted_data "$TARGET_DIR/$tgt_file2"
              SEALED_NOTES+=("- \`[RENAMED]\` \`$tgt_file1\` → \`$tgt_file2\` — encryptedData blanked; re-seal for this cluster")
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

        # ── Modified ──────────────────────────────────────────────────────────
        M)
          tgt_file=$(_sub_path "$file1")
          if is_sealed_secret "$SOURCE_DIR/$file1"; then
            SEALED_NOTES+=("- \`[MODIFIED]\` \`$tgt_file\` — **skipped** (cluster-specific encryption; re-seal manually if value changed)")
          else
            merge_rc=0
            three_way_merge_file "$file1" "$tgt_file" "$TARGET_DIR" "$SED_SCRIPT" || merge_rc=$?
            [[ $merge_rc -eq 1 ]] && CONFLICT_FILES+=("$tgt_file")
            if has_image_lines "$TARGET_DIR/$tgt_file" 2>/dev/null; then
              IMAGE_NOTES+=("- \`[MODIFIED]\` \`$tgt_file\` — image tags preserved from target")
            fi
            git -C "$TARGET_DIR" add "$tgt_file"
            HAS_CHANGES=true
          fi
          ;;

        # ── Added / Copied ────────────────────────────────────────────────────
        A|C|*)
          src_file="${file2:-$file1}"
          tgt_file=$(_sub_path "$src_file")

          if is_sealed_secret "$SOURCE_DIR/$src_file"; then
            src_name=$(get_sealed_secret_name "$SOURCE_DIR/$src_file")
            src_other=$(find_sealed_secret_by_name \
              "$src_name" "$SOURCE_DIR" "$SOURCE_DIR/$src_file" || true)
            mkdir -p "$(dirname "$TARGET_DIR/$tgt_file")"

            if [[ -n "$src_other" ]]; then
              # It's a copy of an existing sealed secret — find matching in target
              tgt_name=$(_sub_path "$src_name")
              tgt_existing=$(find_sealed_secret_by_name "$tgt_name" "$TARGET_DIR" || true)
              if [[ -n "$tgt_existing" ]]; then
                cp "$tgt_existing" "$TARGET_DIR/$tgt_file"
                apply_subs "$TARGET_DIR/$tgt_file" "$SED_SCRIPT"
                SEALED_NOTES+=("- \`[COPIED]\` \`$tgt_file\` — target's own secret copied from \`${tgt_existing#"$TARGET_DIR/"}\` (encrypted values preserved)")
              else
                copy_and_apply "$src_file" "$tgt_file" "$TARGET_DIR" "$SED_SCRIPT"
                strip_encrypted_data "$TARGET_DIR/$tgt_file"
                SEALED_NOTES+=("- \`[COPIED]\` \`$tgt_file\` — no matching secret found in target; encryptedData blanked, re-seal for this cluster")
              fi
            else
              # Truly new sealed secret
              copy_and_apply "$src_file" "$tgt_file" "$TARGET_DIR" "$SED_SCRIPT"
              strip_encrypted_data "$TARGET_DIR/$tgt_file"
              SEALED_NOTES+=("- \`[ADDED]\` \`$tgt_file\` — new secret; encryptedData blanked, re-seal for this cluster")
            fi
            git -C "$TARGET_DIR" add "$tgt_file"
            HAS_CHANGES=true

          else
            if copy_and_apply "$src_file" "$tgt_file" "$TARGET_DIR" "$SED_SCRIPT"; then
              if has_image_lines "$TARGET_DIR/$tgt_file"; then
                IMAGE_NOTES+=("- \`[ADDED]\` \`$tgt_file\` — new file; image tags copied from source (review if needed)")
              fi
              git -C "$TARGET_DIR" add "$tgt_file"
              HAS_CHANGES=true
            fi
          fi
          ;;

      esac
    done <<< "$CHANGED_FILES"

    if ! $HAS_CHANGES; then
      if [[ ${#SEALED_NOTES[@]} -gt 0 ]]; then
        log_warn "$TARGET_NAME: only sealed-secret skips — nothing to commit"
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
    [[ ${#SEALED_NOTES[@]} -gt 0 ]] && SEALED_SECTION="

### Sealed Secrets — manual action required

$(printf '%s\n' "${SEALED_NOTES[@]}")

Run \`kubeseal\` to encrypt values for this cluster before merging."

    IMAGE_SECTION=""
    [[ ${#IMAGE_NOTES[@]} -gt 0 ]] && IMAGE_SECTION="

### Image tags

$(printf '%s\n' "${IMAGE_NOTES[@]}")

Image tags are environment-specific and were not copied from source."

    CONFLICT_SECTION=""
    [[ ${#CONFLICT_FILES[@]} -gt 0 ]] && CONFLICT_SECTION="

### Merge conflicts — resolve before merging

$(for _cf in "${CONFLICT_FILES[@]}"; do printf '%s\n' "- \`$_cf\`"; done)

These files contain \`<<<<<<<\` conflict markers. Edit them to resolve, then commit."

    PR_BODY="## Deploy Sync

Automated sync from \`${SOURCE_REPO}\`

| | |
|---|---|
| **Source** | \`${SOURCE_REPO}\` |
| **Ref range** | \`${FROM_REF}\` → \`${TO_REF}\` |
| **Branch** | \`${SYNC_BRANCH}\` |
| **Timestamp** | \`${TIMESTAMP}\` |

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
[[ ${#PASS[@]} -gt 0 ]] && log_info  "Succeeded (${#PASS[@]}): ${PASS[*]}"
[[ ${#FAIL[@]} -gt 0 ]] && log_error "Failed    (${#FAIL[@]}): ${FAIL[*]}"
[[ ${#FAIL[@]} -eq 0 ]]
