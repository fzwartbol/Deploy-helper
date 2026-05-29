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

Syncs deploy-repo (or app-repo) changes to all configured Bitbucket repos,
applying per-repo name substitutions, preserving image tags, and handling
Sealed Secrets.

Options:
  --source <name>    Source app name (from repos list)
  --type <type>      Section type to sync: deploy|app  (default: deploy)
  --mode <mode>      Sync mode: diff|copy               (default: diff)
  --branch <name>    Source branch to check out  (default: base_branch from config)
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
  sync-deploy.sh --source source --type deploy --from v1.2.0 --to v1.3.0
  sync-deploy.sh --source source --type app --targets app-a,app-b --dry-run
  sync-deploy.sh --source source --mode copy --from v1.0.0 --to v1.1.0
EOF
}

# ── argument parsing ──────────────────────────────────────────────────────────
SOURCE_NAME=""
SOURCE_BRANCH=""
FROM_REF="HEAD~1"
TO_REF="HEAD"
FROM_EXPLICIT=false
TO_EXPLICIT=false
FILTER_TARGETS="all"
DRY_RUN=false
SYNC_TYPE=""
SYNC_MODE="diff"

while [[ $# -gt 0 ]]; do
  case $1 in
    --source)  SOURCE_NAME="$2"; shift 2 ;;
    --type)    SYNC_TYPE="$2"; shift 2 ;;
    --mode)    SYNC_MODE="$2"; shift 2 ;;
    --branch)  SOURCE_BRANCH="$2"; shift 2 ;;
    --from)    FROM_REF="$2"; FROM_EXPLICIT=true; shift 2 ;;
    --to)      TO_REF="$2";   TO_EXPLICIT=true;   shift 2 ;;
    --targets) FILTER_TARGETS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true;  shift   ;;
    --config)  CONFIG_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0  ;;
    *) log_error "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Validate --mode and --type
case "$SYNC_MODE" in
  diff|copy) ;;
  *) log_error "Invalid --mode '$SYNC_MODE'; must be diff or copy"; exit 1 ;;
esac
if [[ -n "$SYNC_TYPE" ]]; then
  case "$SYNC_TYPE" in
    deploy|app) ;;
    *) log_error "Invalid --type '$SYNC_TYPE'; must be deploy or app"; exit 1 ;;
  esac
fi

# ── prerequisites ─────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || { log_error "Config not found: $CONFIG_FILE"; exit 1; }
for _c in git curl awk patch diff; do
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

# Brace-depth tracking one-liner:
#   { pd=d; tmp=$0; d+=gsub(/{/,"",tmp); tmp=$0; d-=gsub(/}/,"",tmp) }
# pd = pre-line depth, d = post-line depth

# Count app entries inside the "apps" array
_cf_app_count() {
  awk '
    { pd=d; tmp=$0; d+=gsub(/{/,"",tmp); tmp=$0; d-=gsub(/}/,"",tmp) }
    /"apps"[[:space:]]*:/ && d==1 { in_apps=1 }
    in_apps && pd==1 && d==2 { c++ }
    END { print c+0 }
  ' "$CONFIG_FILE"
}

# 0-based name of app entry
_cf_app_name() {
  awk -F'"' -v idx="$1" '
    { pd=d; tmp=$0; d+=gsub(/{/,"",tmp); tmp=$0; d-=gsub(/}/,"",tmp) }
    /"apps"[[:space:]]*:/ && d==1 { in_apps=1 }
    in_apps && pd==1 && d==2 { entry++ }
    in_apps && entry==idx+1 && pd==2 && $2=="name" && NF>=4 { print $4; exit }
  ' "$CONFIG_FILE"
}

# 0-based index by name, or "null"
_cf_app_index() {
  awk -F'"' -v name="$1" '
    { pd=d; tmp=$0; d+=gsub(/{/,"",tmp); tmp=$0; d-=gsub(/}/,"",tmp) }
    /"apps"[[:space:]]*:/ && d==1 { in_apps=1 }
    in_apps && pd==1 && d==2 { entry++ }
    in_apps && entry>0 && pd==2 && $2=="name" && NF>=4 {
      if ($4==name) { print entry-1; found=1; exit }
    }
    END { if (!found) print "null" }
  ' "$CONFIG_FILE"
}

# Repo path for type "deploy" or "app"
_cf_app_repo() {
  local idx="$1" type="$2"
  awk -F'"' -v idx="$idx" -v type="$type" '
    { pd=d; tmp=$0; d+=gsub(/{/,"",tmp); tmp=$0; d-=gsub(/}/,"",tmp) }
    /"apps"[[:space:]]*:/ && d==1 { in_apps=1 }
    in_apps && pd==1 && d==2 { entry++; in_type=0 }
    in_apps && entry==idx+1 && pd==2 && $2==type { in_type=1 }
    in_type && pd==3 && $2=="repo" && NF>=4 { print $4; exit }
  ' "$CONFIG_FILE"
}

# Whether app at idx has the given type section (deploy/app)
_cf_app_has_type() {
  [[ -n "$(_cf_app_repo "$1" "$2")" ]]
}

# KEY<TAB>VALUE substitutions lines
_cf_app_subs() {
  local idx="$1" type="$2"
  awk -F'"' -v idx="$idx" -v type="$type" '
    { pd=d; tmp=$0; d+=gsub(/{/,"",tmp); tmp=$0; d-=gsub(/}/,"",tmp) }
    /"apps"[[:space:]]*:/ && d==1 { in_apps=1 }
    in_apps && pd==1 && d==2 { entry++; in_type=0; in_subs=0 }
    in_apps && entry==idx+1 && pd==2 && $2==type { in_type=1 }
    in_type && pd==3 && $2=="substitutions" { in_subs=1 }
    in_subs && d<4 && pd>=4 { in_subs=0 }
    in_subs && pd==4 && $2!="" && NF>=4 && $3~/^:/ { print $2 "\t" $4 }
  ' "$CONFIG_FILE"
}

# Newline-separated list of app names that have the given type section
# type="" means all apps
_cf_app_names_csv() {
  local type="${1:-}"
  if [[ -z "$type" ]]; then
    awk -F'"' '
      { pd=d; tmp=$0; d+=gsub(/{/,"",tmp); tmp=$0; d-=gsub(/}/,"",tmp) }
      /"apps"[[:space:]]*:/ && d==1 { in_apps=1 }
      in_apps && pd==1 && d==2 { entry++ }
      in_apps && entry>0 && pd==2 && $2=="name" && NF>=4 { printf "%s%s", (sep?", ":""), $4; sep=1 }
      END { if (sep) print "" }
    ' "$CONFIG_FILE"
  else
    awk -F'"' -v type="$type" '
      { pd=d; tmp=$0; d+=gsub(/{/,"",tmp); tmp=$0; d-=gsub(/}/,"",tmp) }
      /"apps"[[:space:]]*:/ && d==1 { in_apps=1 }
      in_apps && pd==1 && d==2 { entry++; cur_name=""; has_type=0 }
      in_apps && entry>0 && pd==2 && $2=="name" && NF>=4 { cur_name=$4 }
      in_apps && entry>0 && pd==2 && $2==type { has_type=1 }
      in_apps && entry>0 && cur_name!="" && has_type { printf "%s%s", (sep?", ":""), cur_name; sep=1; cur_name=""; has_type=0 }
      END { if (sep) print "" }
    ' "$CONFIG_FILE"
  fi
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

# Build a clone URL from a repo value.
# If the value is already a full URL (git@..., https://, ssh://) it is used
# as-is.  Otherwise it is treated as a bare "workspace/repo" path: SSH is used
# by default; HTTPS only when both BITBUCKET_USER and BITBUCKET_TOKEN are set.
_bb_url() {
  local repo="$1"
  case "$repo" in
    git@*|https://*|ssh://*|http://*)
      printf '%s' "$repo" ;;
    *)
      if [[ -n "${BITBUCKET_USER:-}" && -n "${BITBUCKET_TOKEN:-}" ]]; then
        printf 'https://%s:%s@bitbucket.org/%s.git' \
          "$BITBUCKET_USER" "$BITBUCKET_TOKEN" "$repo"
      else
        printf 'git@bitbucket.org:%s.git' "$repo"
      fi ;;
  esac
}

# Convert configured repo values, including SSH clone URLs, to workspace/repo.
_bb_repo_slug() {
  local repo="$1"
  case "$repo" in
    git@bitbucket.org:*)
      repo="${repo#git@bitbucket.org:}" ;;
    ssh://git@bitbucket.org/*)
      repo="${repo#ssh://git@bitbucket.org/}" ;;
    https://bitbucket.org/*|http://bitbucket.org/*)
      repo="${repo#*://bitbucket.org/}" ;;
  esac
  repo="${repo%.git}"
  printf '%s' "$repo"
}

# Clone repo or reset an existing clone to origin/<BASE_BRANCH>
clone_or_update() {
  local repo="$1" dir="$2" branch="${3:-$BASE_BRANCH}"
  local url; url=$(_bb_url "$repo")
  if [[ -d "$dir/.git" ]]; then
    log_info "Fetching $repo"
    git -C "$dir" remote set-url origin "$url"
    git -C "$dir" fetch origin
    git -C "$dir" checkout "$branch"
    git -C "$dir" reset --hard "origin/$branch"
  else
    log_info "Cloning $repo"
    git clone --branch "$branch" "$url" "$dir"
  fi
  git -C "$dir" config user.email \
    "$(git config --global user.email 2>/dev/null || printf 'sync-deploy@automation')"
  git -C "$dir" config user.name \
    "$(git config --global user.name  2>/dev/null || printf 'Deploy Sync Bot')"
  git -C "$dir" config advice.addIgnoredFile false
}

# Fetch tag names from a remote without cloning (for interactive menus)
_fetch_tags() {
  git ls-remote --tags "$(_bb_url "$1")" 2>/dev/null \
    | grep -v '\^{}' \
    | awk '{print $2}' \
    | sed 's|refs/tags/||' \
    | { sort -Vr 2>/dev/null || sort -r; }
}

_fetch_branches() {
  git ls-remote --heads "$(_bb_url "$1")" 2>/dev/null \
    | awk '{print $2}' \
    | sed 's|refs/heads/||' \
    | sort
}

# ── file-processing helpers ───────────────────────────────────────────────────

is_text_file()     { grep -qI '' "$1" 2>/dev/null; }
is_sealed_secret() {
  is_text_file "$1" && grep -q '^kind:[[:space:]]*SealedSecret' "$1" 2>/dev/null
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
# Both arguments are KEY<TAB>VALUE lines (from _cf_app_subs).
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
    BEGIN { cnt=0 }
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
  sed -i.bak "$sed_script" "$file" && rm -f "$file.bak"
}

# Apply substitutions to a full path string (filename + directories).
# Uses the same SED_SCRIPT as file content so one set of substitution rules
# covers everything: file content, filenames, directory names, module names.
_sub_path() {
  if [[ -z "${SED_SCRIPT:-}" ]]; then
    printf '%s' "$1"
  else
    printf '%s' "$1" | sed "$SED_SCRIPT"
  fi
}

# Resolve the source file to read for a mapped target path.
# If the target path also exists in the source repo, prefer that counterpart
# instead of copying the file from the original changed path into every target.
_source_path_for_target() {
  local src_rel="$1" tgt_rel="$2"
  if [[ "$src_rel" != "$tgt_rel" && -f "$SOURCE_DIR/$tgt_rel" ]]; then
    printf '%s' "$tgt_rel"
  else
    printf '%s' "$src_rel"
  fi
}

# Copy src_rel from SOURCE_DIR to tgt_dir/tgt_rel, then apply name subs.
# Returns 1 (non-fatal) when the source file is absent.
copy_and_apply() {
  local src_rel="$1" tgt_rel="$2" tgt_dir="$3" sed_script="$4"
  src_rel=$(_source_path_for_target "$src_rel" "$tgt_rel")
  local src_abs="$SOURCE_DIR/$src_rel"
  if [[ ! -f "$src_abs" ]]; then
    log_warn "Source file missing: $src_rel — skipping"
    return 1
  fi
  mkdir -p "$(dirname "$tgt_dir/$tgt_rel")"
  cp "$src_abs" "$tgt_dir/$tgt_rel"
  log_info "copy_and_apply: src=$src_rel"
  log_info "copy_and_apply: sed=[$sed_script]"
  apply_subs "$tgt_dir/$tgt_rel" "$sed_script"
  log_info "copy_and_apply result (first 3 lines): $(head -3 "$tgt_dir/$tgt_rel" | tr '\n' '|')"
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


# Set stages so IntelliJ opens the 3-way merge tool showing ONLY source changes.
#
# Neutralises env-specific content (image tags, protected ConfigMap keys) so
# those lines are invisible to the diff.  Working tree stays as clean target.
#
# Stage 1 = source_A neutralised (BASE): IntelliJ highlights only lines that
#           source actually changed (v1→v2) — not every diff vs the target.
# Stage 2 = target original (LEFT): target's customisations shown on left side.
# Stage 3 = source_B neutralised (RIGHT): source end state; only v1→v2 changes
#           are highlighted green/blue.  Target-equal lines are unlit.
#
# Returns: 0=already in sync (no diffs), 1=stages set (needs manual merge)
patch_merge_file() {
  local orig_src="$1" tgt_path="$2" tgt_dir="$3" sed_script="$4"

  local src_path
  src_path=$(_source_path_for_target "$orig_src" "$tgt_path")
  local src_abs="$SOURCE_DIR/$src_path"
  local tgt_abs="$tgt_dir/$tgt_path"

  local base theirs
  base=$(mktemp   "$WORK_DIR/.pm_base_XXXXXX")
  theirs=$(mktemp "$WORK_DIR/.pm_theirs_XXXXXX")

  # base: source at FROM_REF; fall back to first-time copy if brand-new
  if ! git -C "$SOURCE_DIR" show "${FROM_REF}:${src_path}" > "$base" 2>/dev/null; then
    rm -f "$base" "$theirs"
    copy_and_apply "$src_path" "$tgt_path" "$tgt_dir" "$sed_script"
    return $?
  fi
  apply_subs "$base" "$sed_script"

  # theirs: source at TO_REF with subs applied
  cp "$src_abs" "$theirs"
  apply_subs "$theirs" "$sed_script"

  if [[ ! -f "$tgt_abs" ]]; then
    mkdir -p "$(dirname "$tgt_abs")"
    log_info "pm first-time copy: src=$src_path -> tgt=$tgt_path"
    cp "$theirs" "$tgt_abs"
    rm -f "$base" "$theirs"
    return 0
  fi

  # Neutralise env-specific content so those lines do not appear as source diffs:
  #   image/tag lines       → restore theirs to base values so diff(base,theirs)=0
  #   protected ConfigMap keys → replace with target values in both so they cancel
  restore_image_lines       "$theirs" "$base"
  neutralize_configmap_keys "$theirs" "$tgt_abs"
  neutralize_configmap_keys "$base"   "$tgt_abs"

  # Nothing to do if source didn't change, or target already matches source_B.
  if diff -q "$base" "$theirs" > /dev/null 2>&1 || \
     diff -q "$tgt_abs" "$theirs" > /dev/null 2>&1; then
    rm -f "$base" "$theirs"
    return 0
  fi

  # Save original target for stage registration.
  local ours_save
  ours_save=$(mktemp "$WORK_DIR/.pm_ours_save_XXXXXX")
  cp "$tgt_abs" "$ours_save"

  log_warn "pm: diffs in $tgt_path — needs manual merge"

  # Register stages for IntelliJ 3-way merge dialog:
  #   Stage 1 = source_A (BASE) → IntelliJ uses this to compute what changed.
  #             Only source's v1→v2 lines are highlighted; target customisations
  #             that are unrelated to the diff appear unlit on the right.
  #   Stage 2 = target original (LEFT)
  #   Stage 3 = source_B (RIGHT)
  local base_hash ours_hash theirs_hash
  base_hash=$(git   -C "$tgt_dir" hash-object -w "$base")
  ours_hash=$(git   -C "$tgt_dir" hash-object -w "$ours_save")
  theirs_hash=$(git -C "$tgt_dir" hash-object -w "$theirs")
  {
    printf '100644 %s 1\t%s\n' "$base_hash"   "$tgt_path"
    printf '100644 %s 2\t%s\n' "$ours_hash"   "$tgt_path"
    printf '100644 %s 3\t%s\n' "$theirs_hash" "$tgt_path"
  } | git -C "$tgt_dir" update-index --index-info

  rm -f "$base" "$theirs" "$ours_save"
  return 1
}

# ── Bitbucket PR creation ─────────────────────────────────────────────────────
create_bitbucket_pr() {
  local repo="$1" branch="$2" title="$3" body="$4"
  local repo_slug; repo_slug=$(_bb_repo_slug "$repo")

  # Credentials must be supplied explicitly — we do NOT call git credential fill
  # because that triggers browser/keychain auth which requires interactive input.
  # Set BITBUCKET_USER and BITBUCKET_TOKEN (an app password, not your login
  # password) to enable automatic PR creation.
  local api_user="${BITBUCKET_USER:-}"
  local api_token="${BITBUCKET_TOKEN:-}"

  if [[ -z "$api_user" || -z "$api_token" ]]; then
    return 0
  fi

  local payload
  payload=$(_pr_payload "$title" "$body" "$branch" "$BASE_BRANCH")

  local response http_code body_json
  response=$(curl -s -w "\n%{http_code}" -X POST \
    -u "${api_user}:${api_token}" \
    -H "Content-Type: application/json" \
    "https://api.bitbucket.org/2.0/repositories/${repo_slug}/pullrequests" \
    -d "$payload")

  http_code=$(tail  -n1  <<< "$response")
  body_json=$(sed '$d' <<< "$response")

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
APP_COUNT=$(_cf_app_count)
PROTECTED_CM_KEYS=$(_cf_protected_keys)

[[ "$APP_COUNT" -gt 0 ]] || { log_error "No apps found in $CONFIG_FILE"; exit 1; }

# Clean work dir at the start of every run for a reproducible state
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# ── Interactive step 0: select sync type ─────────────────────────────────────
if [[ -z "$SYNC_TYPE" ]]; then
  if $_INTERACTIVE; then
    echo ""
    echo "### sync-deploy.sh ###"
    echo "Config: $CONFIG_FILE"
    echo ""
    echo "Steps: (0) type  (1) source repo  (2) branch  (3) FROM ref  (4) TO ref  (5) target(s)"
    echo ""
    echo "--- Step 0: What do you want to sync? ---"
    echo "  1) Deploy repos"
    echo "  2) App repos"
    printf 'Enter number [1-2, ENTER=1]: '
    read -r _pick 2>/dev/null || _pick=""
    [[ -z "$_pick" ]] && _pick=1
    case "$_pick" in
      2) SYNC_TYPE="app" ;;
      *) SYNC_TYPE="deploy" ;;
    esac
    echo "-> $SYNC_TYPE"
    echo ""
    unset _pick
  else
    SYNC_TYPE="deploy"
  fi
fi

# Pre-load app list filtered by SYNC_TYPE
_ANAMES=(); _AREPOS=()
for ((_i=0; _i<APP_COUNT; _i++)); do
  _n=$(_cf_app_name "$_i")
  _r=$(_cf_app_repo "$_i" "$SYNC_TYPE")
  if [[ -n "$_r" ]]; then
    _ANAMES+=("$_n")
    _AREPOS+=("$_r")
  fi
done
_ACOUNT=${#_ANAMES[@]}

# ── Interactive step 1: source repo ──────────────────────────────────────────
if [[ -z "$SOURCE_NAME" ]]; then
  if ! $_INTERACTIVE; then
    log_error "--source is required in non-interactive mode"
    log_error "Available apps (${SYNC_TYPE}): $(_cf_app_names_csv "$SYNC_TYPE")"
    usage; exit 1
  fi

  if [[ ! $_INTERACTIVE == true ]]; then
    echo ""
    echo "### sync-deploy.sh ###"
    echo "Config: $CONFIG_FILE"
    echo ""
    echo "Steps: (1) source repo  (2) branch  (3) FROM ref  (4) TO ref  (5) target(s)"
    echo ""
  fi
  echo "--- Step 1: Select SOURCE repo ---"
  echo "The diff will be computed on this repo."
  echo ""
  for ((_i=0; _i<_ACOUNT; _i++)); do
    printf '  %d) %-24s  (%s)\n' "$((_i+1))" "${_ANAMES[$_i]}" "${_AREPOS[$_i]}"
  done
  echo ""

  if [[ "$_ACOUNT" -eq 1 ]]; then
    SOURCE_NAME="${_ANAMES[0]}"
    echo "Only one repo — auto-selected: $SOURCE_NAME"
    echo ""
  elif [[ "$_ACOUNT" -eq 0 ]]; then
    log_error "No apps with type '$SYNC_TYPE' found in $CONFIG_FILE"
    exit 1
  else
    while true; do
      printf 'Enter number [1-%d, ENTER=1]: ' "$_ACOUNT"
      read -r _pick 2>/dev/null || _pick=""
      [[ -z "$_pick" ]] && _pick=1
      if [[ "$_pick" =~ ^[0-9]+$ ]] && ((_pick >= 1 && _pick <= _ACOUNT)); then
        SOURCE_NAME="${_ANAMES[$((_pick-1))]}"
        echo "-> $SOURCE_NAME"
        echo ""
        break
      fi
      printf 'Enter a number between 1 and %d.\n' "$_ACOUNT"
    done
    unset _pick
  fi
fi

# ── Early source clone for date-sorted branch/tag listing ─────────────────────
# Done right after SOURCE_NAME is known so steps 2 & 3 can use local git.
SOURCE_DIR="$WORK_DIR/source-${SYNC_TYPE}"
if $_INTERACTIVE && [[ -n "$SOURCE_NAME" ]] && ! $DRY_RUN; then
  _early_idx=$(_cf_app_index "$SOURCE_NAME")
  _early_repo=$(_cf_app_repo "$_early_idx" "$SYNC_TYPE")
  if [[ -n "$_early_repo" ]]; then
    log_info "Fetching source repo for branch/tag listing..."
    clone_or_update "$_early_repo" "$SOURCE_DIR" "$BASE_BRANCH" >/dev/null 2>&1 || true
  fi
  unset _early_idx _early_repo
fi

# ── Interactive step 2: source branch ────────────────────────────────────────
if [[ -z "$SOURCE_BRANCH" ]] && $_INTERACTIVE; then
  echo "--- Step 2: Select source BRANCH ---"
  _branches=()
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    while IFS= read -r _b; do
      _b="${_b#"${_b%%[![:space:]]*}"}"   # ltrim
      _b="${_b#*/}"                       # strip remote prefix (origin/)
      [[ -n "$_b" ]] && _branches+=("$_b")
    done < <(git -C "$SOURCE_DIR" branch -r --sort=-committerdate 2>/dev/null \
               | grep -v 'HEAD' || true)
  else
    _src_repo_for_br=""
    for ((_i=0; _i<_ACOUNT; _i++)); do
      [[ "${_ANAMES[$_i]}" == "$SOURCE_NAME" ]] && { _src_repo_for_br="${_AREPOS[$_i]}"; break; }
    done
    log_info "Fetching branches from ${_src_repo_for_br} ..."
    while IFS= read -r _b; do [[ -n "$_b" ]] && _branches+=("$_b"); done \
      < <(_fetch_branches "$_src_repo_for_br" 2>/dev/null || true)
    unset _src_repo_for_br
  fi

  if [[ ${#_branches[@]} -eq 0 ]]; then
    SOURCE_BRANCH="$BASE_BRANCH"
    echo "No branches found — using default: $SOURCE_BRANCH"
    echo ""
  else
    _nb=${#_branches[@]}
    _pg=0; _pgsz=20
    while true; do
      _pgs=$(( _pg * _pgsz )); _pge=$(( _pgs + _pgsz ))
      [[ $_pge -gt $_nb ]] && _pge=$_nb
      echo ""
      for ((_j=_pgs; _j<_pge; _j++)); do
        printf '  %d) %s\n' "$((_j+1))" "${_branches[$_j]}"
      done
      if [[ $_nb -gt $_pge ]]; then
        printf '  (showing %d–%d of %d — enter n for next page)\n' \
          "$((_pgs+1))" "$_pge" "$_nb"
        printf '\nEnter number [1-%d, ENTER=1, n=next]: ' "$_nb"
      else
        printf '\nEnter number [1-%d, ENTER=1]: ' "$_nb"
      fi
      read -r _pick 2>/dev/null || _pick=""
      [[ -z "$_pick" ]] && _pick=1
      if [[ ("$_pick" == "n" || "$_pick" == "N") && $_nb -gt $_pge ]]; then
        _pg=$(( _pg + 1 )); continue
      fi
      { [[ "$_pick" =~ ^[0-9]+$ ]] && ((_pick >= 1 && _pick <= _nb)); } || _pick=1
      SOURCE_BRANCH="${_branches[$((_pick-1))]}"
      echo "-> $SOURCE_BRANCH"
      echo ""
      break
    done
    unset _nb _pg _pgsz _pgs _pge _j _pick
  fi
  unset _branches _b
fi
[[ -z "$SOURCE_BRANCH" ]] && SOURCE_BRANCH="$BASE_BRANCH"

# ── Interactive step 3: FROM and TO refs ─────────────────────────────────────
if ! $FROM_EXPLICIT || ! $TO_EXPLICIT; then
  if $_INTERACTIVE; then
    # Prefer date-sorted tags from local clone; fall back to remote ls
    _tags=()
    if [[ -d "$SOURCE_DIR/.git" ]]; then
      while IFS= read -r _t; do [[ -n "$_t" ]] && _tags+=("$_t"); done \
        < <(git -C "$SOURCE_DIR" tag --sort=-creatordate 2>/dev/null || true)
    else
      _src_repo=""
      for ((_i=0; _i<_ACOUNT; _i++)); do
        [[ "${_ANAMES[$_i]}" == "$SOURCE_NAME" ]] && { _src_repo="${_AREPOS[$_i]}"; break; }
      done
      log_info "Fetching tags from ${_src_repo} ..."
      while IFS= read -r _t; do [[ -n "$_t" ]] && _tags+=("$_t"); done \
        < <(_fetch_tags "$_src_repo" 2>/dev/null || true)
      unset _src_repo
    fi

    # Scrollable paginated tag/ref picker.
    # Usage: _pick_ref VARNAME TITLE DEFAULT_LABEL DEFAULT_VALUE [items…]
    _pick_ref() {
      local _rv="$1" _title="$2" _dlabel="$3" _dval="$4"; shift 4
      local -a _labels=("$_dlabel") _values=("$_dval")
      local _x; for _x in "$@"; do _labels+=("$_x"); _values+=("$_x"); done
      local _n=${#_labels[@]}
      local _pg=0 _pgsz=20

      while true; do
        local _pgs=$(( _pg * _pgsz )) _pge=$(( _pg * _pgsz + _pgsz ))
        [[ $_pge -gt $_n ]] && _pge=$_n
        echo "--- $_title ---"
        echo ""
        local _j
        for ((_j=_pgs; _j<_pge; _j++)); do
          printf '  %d) %s\n' "$((_j+1))" "${_labels[$_j]}"
        done
        if [[ $_n -gt $_pge ]]; then
          printf '  (showing %d–%d of %d — enter n for next page)\n' \
            "$((_pgs+1))" "$_pge" "$((_n-1))"
          printf '\nEnter number [1-%d, ENTER=1, n=next]: ' "$_n"
        else
          printf '\nEnter number [1-%d, ENTER=1]: ' "$_n"
        fi
        local _r; read -r _r 2>/dev/null || _r=""
        [[ -z "$_r" ]] && _r=1
        if [[ ("$_r" == "n" || "$_r" == "N") && $_n -gt $_pge ]]; then
          _pg=$(( _pg + 1 )); continue
        fi
        { [[ "$_r" =~ ^[0-9]+$ ]] && ((_r>=1 && _r<=_n)); } || _r=1
        printf -v "$_rv" '%s' "${_values[$((_r-1))]}"
        echo "-> ${_labels[$((_r-1))]}"
        echo ""
        return
      done
    }

    printf '\n'
    $FROM_EXPLICIT || _pick_ref FROM_REF \
      "Step 3a: FROM ref (start of diff — older tag/commit)" \
      "HEAD~1 — previous commit (default)" "HEAD~1" \
      "${_tags[@]+"${_tags[@]}"}"
    $TO_EXPLICIT   || _pick_ref TO_REF \
      "Step 3b: TO ref (end of diff — newer tag/commit)" \
      "HEAD — latest commit (default)" "HEAD" \
      "${_tags[@]+"${_tags[@]}"}"
    unset _t _tags
  fi
fi

# ── Interactive step 4: target repos ─────────────────────────────────────────
if [[ "$FILTER_TARGETS" == "all" ]]; then
  _tgt_names=(); _tgt_repos=()
  for ((_i=0; _i<_ACOUNT; _i++)); do
    [[ "${_ANAMES[$_i]}" == "$SOURCE_NAME" ]] && continue
    _tgt_names+=("${_ANAMES[$_i]}")
    _tgt_repos+=("${_AREPOS[$_i]}")
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
    echo "--- Step 4: Select TARGET repo(s) ---"
    echo "The diff ($FROM_REF -> $TO_REF) will be applied to these repos."
    echo ""
    for ((_i=0; _i<_nt; _i++)); do
      printf '  %d) %-24s  (%s)\n' "$((_i+1))" "${_tgt_names[$_i]}" "${_tgt_repos[$_i]}"
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
  unset _tgt_names _tgt_repos _nt
fi
unset _ANAMES _AREPOS _i

# ── Compute branch name ───────────────────────────────────────────────────────
SYNC_BRANCH="sync/${SYNC_TYPE}-${SYNC_MODE}-from-$(_sanitize_ref "$FROM_REF")-to-$(_sanitize_ref "$TO_REF")"

# ═════════════════════════════════════════════════════════════════════════════
# Sync engine — no interactive code below this line
# ═════════════════════════════════════════════════════════════════════════════

[[ -n "$SOURCE_NAME" ]] || { log_error "--source is required"; exit 1; }

_src_idx=$(_cf_app_index "$SOURCE_NAME")
if [[ "$_src_idx" == "null" ]]; then
  log_error "Source app '$SOURCE_NAME' not found in $CONFIG_FILE"
  log_error "Available: $(_cf_app_names_csv)"
  exit 1
fi
SOURCE_REPO=$(_cf_app_repo   "$_src_idx" "$SYNC_TYPE")
if [[ -z "$SOURCE_REPO" ]]; then
  log_error "Source app '$SOURCE_NAME' has no '$SYNC_TYPE' section in $CONFIG_FILE"
  exit 1
fi
SOURCE_SUBS=$(_cf_app_subs "$_src_idx" "$SYNC_TYPE")
unset _src_idx

SOURCE_DIR="$WORK_DIR/source-${SYNC_TYPE}"
log_section "Source: $SOURCE_NAME  ($SOURCE_REPO)  [$FROM_REF → $TO_REF]  type=$SYNC_TYPE  mode=$SYNC_MODE"

if $DRY_RUN; then
  log_info "[DRY RUN] Would clone $SOURCE_REPO and diff $FROM_REF..$TO_REF"
  CHANGED_FILES=$'M\texample/deployment.yaml\nA\tsecrets/new-secret.yaml\nD\texample/old.yaml'
else
  clone_or_update "$SOURCE_REPO" "$SOURCE_DIR" "$SOURCE_BRANCH"
  if [[ "$SYNC_MODE" == "diff" ]]; then
    CHANGED_FILES=$(git -C "$SOURCE_DIR" diff --find-renames=80% --name-status "$FROM_REF" "$TO_REF" || true)
  fi
fi

if [[ "$SYNC_MODE" == "diff" ]]; then
  [[ -n "${CHANGED_FILES:-}" ]] || { log_warn "No changes between $FROM_REF and $TO_REF"; exit 0; }

  log_info "Changed files:"
  while IFS=$'\t' read -r status f1 f2; do
    op="${status:0:1}"
    if [[ "$op" == "R" || "$op" == "C" ]] && [[ -n "$f2" ]]; then
      printf '  [%s] %s  →  %s\n' "$status" "$f1" "$f2"
    else
      printf '  [%s] %s\n' "$status" "$f1"
    fi
  done <<< "$CHANGED_FILES"

  CHANGED_FILES_MD=$(
    while IFS=$'\t' read -r s f1 f2; do
      printf '%s\n' "- \`[$s]\` \`${f2:-$f1}\`"
    done <<< "$CHANGED_FILES"
  )
fi

# ── copy mode function ────────────────────────────────────────────────────────
sync_copy_mode() {
  # Receives: TARGET_DIR, SED_SCRIPT, SOURCE_DIR, TO_REF
  # all set as variables in the calling subshell

  # Safety: list all source files at TO_REF
  local src_files
  src_files=$(git -C "$SOURCE_DIR" ls-tree -r --name-only "$TO_REF" 2>/dev/null || true)

  if [[ -z "$src_files" ]]; then
    log_error "copy mode: source has 0 files at $TO_REF — refusing to delete everything"
    exit 1
  fi

  declare -A tgt_projected
  local tmp
  tmp=$(mktemp "$WORK_DIR/.copy_tmp_XXXXXX")

  while IFS= read -r src_file; do
    [[ -z "$src_file" ]] && continue

    local tgt_file
    tgt_file=$(_sub_path "$src_file")
    tgt_projected["$tgt_file"]=1

    # Extract source file content at TO_REF
    git -C "$SOURCE_DIR" show "${TO_REF}:${src_file}" > "$tmp" 2>/dev/null || {
      log_warn "copy mode: cannot read ${TO_REF}:${src_file} — skipping"
      continue
    }

    apply_subs "$tmp" "$SED_SCRIPT"

    if is_sealed_secret "$tmp"; then
      strip_encrypted_data "$tmp"
      SEALED_NOTES+=("- \`[COPY]\` \`$tgt_file\` — encryptedData blanked; re-seal for this cluster")
    fi

    # Preserve image lines from existing target file before overwriting
    local saved_orig
    saved_orig=$(mktemp "$WORK_DIR/.copy_orig_XXXXXX")
    if [[ -f "$TARGET_DIR/$tgt_file" ]]; then
      cp "$TARGET_DIR/$tgt_file" "$saved_orig"
    fi

    mkdir -p "$(dirname "$TARGET_DIR/$tgt_file")"
    cp "$tmp" "$TARGET_DIR/$tgt_file"

    # Restore image lines from the saved original (if it existed)
    if [[ -s "$saved_orig" ]]; then
      restore_image_lines "$TARGET_DIR/$tgt_file" "$saved_orig"
      if has_image_lines "$TARGET_DIR/$tgt_file" 2>/dev/null; then
        IMAGE_NOTES+=("- \`[COPY]\` \`$tgt_file\` — image tags preserved from target")
      fi
    elif has_image_lines "$TARGET_DIR/$tgt_file" 2>/dev/null; then
      IMAGE_NOTES+=("- \`[COPY]\` \`$tgt_file\` — new file; image tags from source")
    fi
    rm -f "$saved_orig"

    git -C "$TARGET_DIR" add "$tgt_file"
    HAS_CHANGES=true

  done <<< "$src_files"

  rm -f "$tmp"

  # Delete target files not in tgt_projected
  while IFS= read -r -d '' f; do
    local rel="${f#"$TARGET_DIR/"}"
    if [[ -z "${tgt_projected[$rel]+x}" ]]; then
      log_info "copy mode: deleting $rel (not in source at $TO_REF)"
      git -C "$TARGET_DIR" rm -f "$rel"
      HAS_CHANGES=true
    fi
  done < <(find "$TARGET_DIR" -not -path '*/.git/*' -type f -print0)
}

# ── Process each target repo ──────────────────────────────────────────────────
PASS=(); FAIL=()
_tgt_num=0

for ((_ti=0; _ti<APP_COUNT; _ti++)); do
  TARGET_NAME=$(_cf_app_name "$_ti")
  TARGET_REPO=$(_cf_app_repo "$_ti" "$SYNC_TYPE")
  TARGET_SUBS=$(_cf_app_subs "$_ti" "$SYNC_TYPE")

  # Skip apps that don't have the SYNC_TYPE section
  if [[ -z "$TARGET_REPO" ]]; then
    log_info "Skipping $TARGET_NAME — no '$SYNC_TYPE' section configured"
    continue
  fi

  is_target_included "$TARGET_NAME" || continue
  _tgt_num=$(( _tgt_num + 1 ))

  log_section "Target [$_tgt_num]: $TARGET_NAME → $TARGET_REPO"

  if $DRY_RUN; then
    SED_SCRIPT=$(build_sed_script "$SOURCE_SUBS" "$TARGET_SUBS")
    log_info "[DRY RUN] Branch             : $SYNC_BRANCH"
    log_info "[DRY RUN] Substitutions      : ${SED_SCRIPT:-(none)}"
    log_info "[DRY RUN] Mode               : $SYNC_MODE"
    PASS+=("$TARGET_NAME (dry-run)")
    continue
  fi

  # Warn and switch to diff if copy mode requested for app repos
  _effective_mode="$SYNC_MODE"
  if [[ "$SYNC_MODE" == "copy" && "$SYNC_TYPE" == "app" ]]; then
    log_warn "copy mode is not supported for app repos — falling back to diff for $TARGET_NAME"
    _effective_mode="diff"
  fi

  (
    set -e
    TARGET_DIR="$WORK_DIR/$TARGET_NAME"
    clone_or_update "$TARGET_REPO" "$TARGET_DIR"
    git -C "$TARGET_DIR" checkout -B "$SYNC_BRANCH"

    SED_SCRIPT=$(build_sed_script "$SOURCE_SUBS" "$TARGET_SUBS")
    log_info "SED_SCRIPT for $TARGET_NAME:"
    log_info "  $SED_SCRIPT"
    HAS_CHANGES=false
    SEALED_NOTES=()
    IMAGE_NOTES=()
    CONFLICT_FILES=()

    if [[ "$_effective_mode" == "copy" ]]; then
      sync_copy_mode
    else
      # diff mode
      while IFS=$'\t' read -r status file1 file2; do
        op="${status:0:1}"  # strip similarity score: R095 → R, C090 → C

        case "$op" in

          # ── Deleted ───────────────────────────────────────────────────────────
          D)
            tgt_file=$(_sub_path "$file1")
            log_info "D  src=$file1  →  tgt=$tgt_file"
            if [[ -f "$TARGET_DIR/$tgt_file" ]]; then
              log_info "D $tgt_file"
              git -C "$TARGET_DIR" rm -f "$tgt_file"
              HAS_CHANGES=true
            else
              log_warn "D $tgt_file — not found in target"
              log_warn "  checked: $TARGET_DIR/$tgt_file"
              log_warn "  parent dir: $(ls "$(dirname "$TARGET_DIR/$tgt_file")" 2>/dev/null | tr '\n' '|' || echo '<dir missing>')"
            fi
            ;;

          # ── Renamed ───────────────────────────────────────────────────────────
          R)
            tgt_file1=$(_sub_path "$file1")
            tgt_file2=$(_sub_path "$file2")

            if [[ "$(dirname "$tgt_file1")" != "$(dirname "$tgt_file2")" ]]; then
              # Cross-directory renames are almost always false positives from
              # git's similarity detector (e.g. two kustomization.yaml files
              # matching each other across unrelated dirs).  Treat as D + A:
              # remove the old path if target has it, copy the new file.
              log_info "R $file1 → $file2 (cross-dir rename; treated as D+A)"
              if [[ -f "$TARGET_DIR/$tgt_file1" ]]; then
                git -C "$TARGET_DIR" rm -f "$tgt_file1"
                HAS_CHANGES=true
              else
                log_warn "R(D) $tgt_file1 — not found in target (already absent, or path mismatch)"
              fi
              if copy_and_apply "$file2" "$tgt_file2" "$TARGET_DIR" "$SED_SCRIPT"; then
                git -C "$TARGET_DIR" add "$tgt_file2"
                HAS_CHANGES=true
              fi
            else
              # Same-directory rename — normal rename handling with image-line restore
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
            fi
            ;;

          # ── Modified ──────────────────────────────────────────────────────────
          M)
            tgt_file=$(_sub_path "$file1")
            log_info "M  src=$file1  →  tgt=$tgt_file"
            if is_sealed_secret "$SOURCE_DIR/$file1"; then
              SEALED_NOTES+=("- \`[MODIFIED]\` \`$tgt_file\` — **skipped** (cluster-specific encryption; re-seal manually if value changed)")
            else
              merge_rc=0
              patch_merge_file "$file1" "$tgt_file" "$TARGET_DIR" "$SED_SCRIPT" || merge_rc=$?
              if [[ $merge_rc -eq 1 ]]; then
                CONFLICT_FILES+=("$tgt_file")
                # Index stages 1/2/3 are already registered — do not git add here
              else
                if has_image_lines "$TARGET_DIR/$tgt_file" 2>/dev/null; then
                  IMAGE_NOTES+=("- \`[MODIFIED]\` \`$tgt_file\` — image tags preserved from target")
                fi
                git -C "$TARGET_DIR" add "$tgt_file"
              fi
              HAS_CHANGES=true
            fi
            ;;

          # ── Added / Copied ────────────────────────────────────────────────────
          A|C|*)
            src_file="${file2:-$file1}"
            tgt_file=$(_sub_path "$src_file")
            log_info "A  src=$src_file  →  tgt=$tgt_file"

            log_info "A  is_sealed_secret($src_file) → $(is_sealed_secret "$SOURCE_DIR/$src_file" && echo YES || echo no)"
            if is_sealed_secret "$SOURCE_DIR/$src_file"; then
              src_name=$(get_sealed_secret_name "$SOURCE_DIR/$src_file")
              src_other=$(find_sealed_secret_by_name \
                "$src_name" "$SOURCE_DIR" "$SOURCE_DIR/$src_file" || true)
              mkdir -p "$(dirname "$TARGET_DIR/$tgt_file")"

              if [[ -n "$src_other" ]]; then
                # It's a copy of an existing sealed secret — find matching in target
                if [[ -n "$SED_SCRIPT" ]]; then
                  tgt_name=$(printf '%s' "$src_name" | sed "$SED_SCRIPT")
                else
                  tgt_name="$src_name"
                fi
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
    fi

    if ! $HAS_CHANGES; then
      if [[ ${#SEALED_NOTES[@]} -gt 0 ]]; then
        log_warn "$TARGET_NAME: only sealed-secret skips — nothing to commit"
        printf '  %s\n' "${SEALED_NOTES[@]}"
      else
        log_warn "$TARGET_NAME: no effective changes — skipping"
      fi
      exit 0
    fi

    # ── Conflict resolution ───────────────────────────────────────────────────
    if [[ "$_effective_mode" == "diff" && ${#CONFLICT_FILES[@]} -gt 0 ]]; then
      if $_INTERACTIVE; then
        log_warn "Conflicts in $TARGET_NAME — launching merge tool..."
        log_warn "Resolve each file, save and close the dialog to continue."
        git -C "$TARGET_DIR" mergetool --no-prompt
        _still=$(git -C "$TARGET_DIR" diff --name-only --diff-filter=U 2>/dev/null || true)
        if [[ -n "$_still" ]]; then
          log_error "Unresolved conflicts remain in $TARGET_NAME — aborting push"
          printf '  %s\n' "$_still" >&2
          exit 1
        fi
      else
        log_warn "Conflicts in $TARGET_NAME (non-interactive) — committing with markers"
        log_warn "Resolve: git fetch origin && git checkout $SYNC_BRANCH && git mergetool"
        for _cf in "${CONFLICT_FILES[@]}"; do
          git -C "$TARGET_DIR" add "$_cf"
        done
      fi
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
    [[ "$_effective_mode" == "diff" && ${#CONFLICT_FILES[@]} -gt 0 ]] && CONFLICT_SECTION="

### Merge conflicts — resolve before merging

$(for _cf in "${CONFLICT_FILES[@]}"; do printf '%s\n' "- \`$_cf\`"; done)

These files contain \`<<<<<<<\` conflict markers. Edit them to resolve, then commit."

    _changed_md="${CHANGED_FILES_MD:-}"
    PR_BODY="## Deploy Sync

Automated sync from \`${SOURCE_REPO}\`

| | |
|---|---|
| **Source** | \`${SOURCE_REPO}\` |
| **Ref range** | \`${FROM_REF}\` → \`${TO_REF}\` |
| **Branch** | \`${SYNC_BRANCH}\` |
| **Timestamp** | \`${TIMESTAMP}\` |

### Changed files
${_changed_md}${SEALED_SECTION}${IMAGE_SECTION}${CONFLICT_SECTION}

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
