#!/usr/bin/env bash
# tests/run-tests.sh
# End-to-end test harness for sync-deploy.sh.
#
# Creates local bare git repos in a temp dir, redirects all Bitbucket URLs via
# git url.insteadOf, injects a mock curl for the PR API, then runs scenarios
# and asserts the resulting file tree in .work/<target>/.
#
# Usage:  bash tests/run-tests.sh
#         bash tests/run-tests.sh --keep   (leave .work/ and T after run)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="$ROOT/sync-deploy.sh"
WORK_DIR="$ROOT/.work"
T=$(mktemp -d)
KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

PASS=0; FAIL=0

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  if $KEEP; then
    echo -e "\n${YELLOW}--keep: leaving temp dir $T and $WORK_DIR${NC}"
  else
    rm -rf "$T"
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

# ── assertion helpers ─────────────────────────────────────────────────────────
_current_section=""
section() {
  _current_section="$1"
  echo -e "\n${CYAN}${BOLD}▶ $1${NC}"
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; PASS=$(( PASS + 1 )); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$(( FAIL + 1 )); }

has()     { grep -qF  "$2" "$1" 2>/dev/null && ok  "$3" || fail "$3  [missing '$2' in ${1##"$WORK_DIR/"}]"; }
has_not() { grep -qF  "$2" "$1" 2>/dev/null && fail "$3  [found '$2' in ${1##"$WORK_DIR/"}]" || ok "$3"; }
exists()  { [[ -f "$1" ]] && ok  "${2:-${1##"$WORK_DIR/"} exists}"  || fail "${2:-${1##"$WORK_DIR/"} exists}"; }
absent()  { [[ ! -f "$1" ]] && ok "${2:-${1##"$WORK_DIR/"} absent}" || fail "${2:-${1##"$WORK_DIR/"} absent}"; }

# ── mock curl (Bitbucket PR API) ──────────────────────────────────────────────
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"api.bitbucket.org"* ]]; then
  echo '{"links":{"html":{"href":"https://bitbucket.org/test/pullrequests/1"}}}'
  echo "201"
else
  exec /usr/bin/curl "$@"
fi
MOCK
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# ── isolated git config (no signing, redirect bitbucket → local bare repos) ──
export GIT_CONFIG_GLOBAL="$T/gitconfig"
git config --global user.email    "test@sync-deploy.test"
git config --global user.name     "Sync-Deploy Test"
git config --global commit.gpgsign false
git config --global tag.gpgsign    false
git config --global init.defaultBranch main

export BITBUCKET_USER=testuser
export BITBUCKET_TOKEN=testtoken
REMOTES="$T/remotes"
mkdir -p "$REMOTES"
git config --global \
  "url.file://${REMOTES}/.insteadOf" \
  "https://testuser:testtoken@bitbucket.org/testspace/"

# ── helpers to build repos ────────────────────────────────────────────────────
_git_cfg() {
  git -C "$1" config user.email "test@sync-deploy.test"
  git -C "$1" config user.name  "Sync-Deploy Test"
}

make_bare() { git init --bare -q "$REMOTES/${1}.git"; }

# Clone the bare repo into a work tree, run a callback (current dir = work tree),
# commit everything, tag (optional), and push.
with_work() {
  local name="$1" tag="${2:-}"
  local work="$T/seed/$name"
  rm -rf "$work"
  git clone -q "file://$REMOTES/${name}.git" "$work"
  _git_cfg "$work"
  pushd "$work" >/dev/null
    "${@:3}"          # call the body function
    git add -A
    git commit -q -m "${tag:-commit}"
    [[ -n "$tag" ]] && git tag "$tag"
    git push -q origin HEAD --tags
  popd >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE REPO  (testspace/source-deploy-repo)
# v1.0.0 → initial state
# v1.1.0 → changes: M configmap, M deployment, A new-service, D old-feature,
#            R configmap-v1→v2, A staging sealed-secret (copy of dev one)
# ─────────────────────────────────────────────────────────────────────────────
make_bare "source-deploy-repo"

source_v1() {
  mkdir -p base overlays/dev

  cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: source-app
  namespace: source-namespace
spec:
  selector:
    matchLabels:
      app: source-app
  template:
    metadata:
      labels:
        app: source-app
    spec:
      serviceAccountName: source-sa
      containers:
        - name: source-app
          image: source-image:v1.0.0
          env:
            - name: APP_NAME
              value: source-app
            - name: PAAS_PROJECT
              value: source-paas-project
EOF

  cat > base/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: source-service
  namespace: source-namespace
spec:
  selector:
    app: source-app
  ports:
    - port: 8080
      targetPort: 8080
EOF

  cat > base/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: source-app-config
  namespace: source-namespace
data:
  DATABASE_URL: source-db.internal
  APP_SETTING: original-value
  SERVICE_NAME: source-service
EOF

  # This file will be deleted in v2
  cat > base/old-feature.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: source-app-old-config
  namespace: source-namespace
data:
  LEGACY_SETTING: old-value
EOF

  cat > base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - configmap.yaml
EOF

  cat > overlays/dev/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - sealed-secret.yaml
  - source-app-configmap-v1.yaml
EOF

  # Sealed secret — will be "copied" to staging overlay in v2
  cat > overlays/dev/sealed-secret.yaml <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: source-app-db-credentials
  namespace: source-namespace
spec:
  encryptedData:
    password: SourceEncryptedPassword==
    username: SourceEncryptedUsername==
EOF

  # File that will be renamed source-app-configmap-v1 → source-app-configmap-v2
  cat > "overlays/dev/source-app-configmap-v1.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: source-app-versioned-config
  namespace: source-namespace
data:
  VERSION: v1
  FEATURE_FLAG: old-flag
EOF
}
with_work "source-deploy-repo" "v1.0.0" source_v1

source_v2() {
  # M: configmap.yaml — DATABASE_URL changed (protected), APP_SETTING updated, NEW_SETTING added
  cat > base/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: source-app-config
  namespace: source-namespace
data:
  DATABASE_URL: changed-db.internal
  APP_SETTING: updated-value
  SERVICE_NAME: source-service
  NEW_SETTING: new-feature-enabled
EOF

  # M: deployment.yaml — image tag bumped (should be preserved), new env var added
  cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: source-app
  namespace: source-namespace
spec:
  selector:
    matchLabels:
      app: source-app
  template:
    metadata:
      labels:
        app: source-app
    spec:
      serviceAccountName: source-sa
      containers:
        - name: source-app
          image: source-image:v2.0.0
          env:
            - name: APP_NAME
              value: source-app
            - name: PAAS_PROJECT
              value: source-paas-project
            - name: NEW_FEATURE
              value: "enabled"
EOF

  # D: old-feature.yaml removed
  rm -f base/old-feature.yaml

  # A: new-service.yaml added (filename contains source-app — tests filename subs)
  mkdir -p overlays/dev
  cat > "overlays/dev/source-app-internal-svc.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: source-app-internal
  namespace: source-namespace
spec:
  selector:
    app: source-app
  ports:
    - port: 9090
      targetPort: 9090
EOF

  # R: rename source-app-configmap-v1.yaml → source-app-configmap-v2.yaml
  git mv "overlays/dev/source-app-configmap-v1.yaml" \
         "overlays/dev/source-app-configmap-v2.yaml"
  cat > "overlays/dev/source-app-configmap-v2.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: source-app-versioned-config
  namespace: source-namespace
data:
  VERSION: v2
  FEATURE_FLAG: new-flag
EOF

  # A: staging overlay sealed-secret — same metadata.name as dev one (= a copy)
  mkdir -p overlays/staging
  cat > overlays/staging/sealed-secret.yaml <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: source-app-db-credentials
  namespace: source-namespace
spec:
  encryptedData:
    password: SourceStagingEncryptedPassword==
    username: SourceStagingEncryptedUsername==
EOF
}
with_work "source-deploy-repo" "v1.1.0" source_v2

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-a  (testspace/app-a-deploy)
# Pre-existing state: synced at v1.0.0 with app-a substitutions applied,
# plus app-a-specific image tags and database URL.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-a-deploy"

app_a_initial() {
  mkdir -p base overlays/dev

  cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-a
  namespace: ns-a
spec:
  selector:
    matchLabels:
      app: app-a
  template:
    metadata:
      labels:
        app: app-a
    spec:
      serviceAccountName: sa-a
      containers:
        - name: app-a
          image: image-a:app-a-prod-1.5.0
          env:
            - name: APP_NAME
              value: app-a
            - name: PAAS_PROJECT
              value: app-a-paas-project
EOF

  cat > base/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: app-a-service
  namespace: ns-a
spec:
  selector:
    app: app-a
  ports:
    - port: 8080
      targetPort: 8080
EOF

  cat > base/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-a-config
  namespace: ns-a
data:
  DATABASE_URL: app-a-postgres.ns-a.svc.cluster.local
  APP_SETTING: original-value
  SERVICE_NAME: app-a-service
EOF

  cat > base/old-feature.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-a-old-config
  namespace: ns-a
data:
  LEGACY_SETTING: old-value
EOF

  cat > base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - configmap.yaml
EOF

  cat > overlays/dev/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - sealed-secret.yaml
  - app-a-configmap-v1.yaml
EOF

  # App-a's own sealed secret — cluster-specific encrypted values
  cat > overlays/dev/sealed-secret.yaml <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: app-a-db-credentials
  namespace: ns-a
spec:
  encryptedData:
    password: AppAClusterEncryptedPassword==
    username: AppAClusterEncryptedUsername==
EOF

  # Renamed file already at app-a path
  cat > "overlays/dev/app-a-configmap-v1.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-a-versioned-config
  namespace: ns-a
data:
  VERSION: v1
  FEATURE_FLAG: old-flag
EOF
}
with_work "app-a-deploy" "" app_a_initial

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-b  (testspace/app-b-deploy)
# Simpler initial state — only base files, no dev overlay yet.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-b-deploy"

app_b_initial() {
  mkdir -p base

  cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-b
  namespace: ns-b
spec:
  selector:
    matchLabels:
      app: app-b
  template:
    metadata:
      labels:
        app: app-b
    spec:
      serviceAccountName: sa-b
      containers:
        - name: app-b
          image: image-b:app-b-release-2.1.0
          env:
            - name: APP_NAME
              value: app-b
            - name: PAAS_PROJECT
              value: app-b-paas-project
EOF

  cat > base/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-b-config
  namespace: ns-b
data:
  DATABASE_URL: app-b-postgres.ns-b.svc.cluster.local
  APP_SETTING: original-value
  SERVICE_NAME: app-b-service
EOF

  cat > base/old-feature.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-b-old-config
  namespace: ns-b
data:
  LEGACY_SETTING: old-value
EOF
}
with_work "app-b-deploy" "" app_b_initial

# ─────────────────────────────────────────────────────────────────────────────
# Generate test repos.json pointing to our local testspace/ repos
# ─────────────────────────────────────────────────────────────────────────────
cat > "$T/repos.test.json" <<'EOF'
{
  "source": {
    "repo": "testspace/source-deploy-repo",
    "substitutions": {
      "service_name":    "source-service",
      "app_name":        "source-app",
      "paas_name":       "source-paas-project",
      "namespace":       "source-namespace",
      "environment":     "source-env",
      "service_account": "source-sa",
      "image_name":      "source-image",
      "context_url":     "source-app.example.com",
      "health_url":      "source-app.example.com/actuator/health"
    }
  },
  "pr": {
    "base_branch":  "main",
    "title_prefix": "chore(sync): "
  },
  "protected_configmap_keys": ["DATABASE_URL"],
  "targets": [
    {
      "name": "app-a",
      "repo": "testspace/app-a-deploy",
      "substitutions": {
        "service_name":    "app-a-service",
        "app_name":        "app-a",
        "paas_name":       "app-a-paas-project",
        "namespace":       "ns-a",
        "environment":     "development",
        "service_account": "sa-a",
        "image_name":      "image-a",
        "context_url":     "app-a.example.com",
        "health_url":      "app-a.example.com/actuator/health"
      }
    },
    {
      "name": "app-b",
      "repo": "testspace/app-b-deploy",
      "substitutions": {
        "service_name":    "app-b-service",
        "app_name":        "app-b",
        "paas_name":       "app-b-paas-project",
        "namespace":       "ns-b",
        "environment":     "production",
        "service_account": "sa-b",
        "image_name":      "image-b",
        "context_url":     "app-b.example.com",
        "health_url":      "app-b.example.com/actuator/health"
      }
    }
  ]
}
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Run the sync  (non-interactive: --from / --to / --targets all explicit)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (v1.0.0 → v1.1.0, all targets)${NC}"
rm -rf "$WORK_DIR"

bash "$SYNC_SCRIPT" \
  --config "$T/repos.test.json" \
  --from v1.0.0 \
  --to   v1.1.0

# ─────────────────────────────────────────────────────────────────────────────
# Assertions
# ─────────────────────────────────────────────────────────────────────────────
A="$WORK_DIR/app-a"
B="$WORK_DIR/app-b"

# ── app-a: ConfigMap (M) ──────────────────────────────────────────────────────
section "app-a  ConfigMap — three-way merge"
has     "$A/base/configmap.yaml"  "APP_SETTING: updated-value"  "non-protected key updated"
has     "$A/base/configmap.yaml"  "NEW_SETTING: new-feature-enabled"  "new key added"
has     "$A/base/configmap.yaml"  "SERVICE_NAME: app-a-service"  "app substitution applied to value"
# DATABASE_URL is in protected_configmap_keys → must stay as app-a's own value
has     "$A/base/configmap.yaml"  "DATABASE_URL: app-a-postgres.ns-a.svc.cluster.local"  "protected DATABASE_URL preserved from target"
has_not "$A/base/configmap.yaml"  "DATABASE_URL: changed-db.internal"  "source DATABASE_URL NOT copied"
has_not "$A/base/configmap.yaml"  "DATABASE_URL: source-db.internal"   "base DATABASE_URL NOT copied"
# ConfigMap metadata uses app-a naming
has     "$A/base/configmap.yaml"  "name: app-a-config"  "ConfigMap name substituted"
has_not "$A/base/configmap.yaml"  "source-app"          "no source-app in configmap"

# ── app-a: Deployment (M) — image tag preservation ───────────────────────────
section "app-a  Deployment — image tag preserved"
has     "$A/base/deployment.yaml"  "image: image-a:app-a-prod-1.5.0"  "image tag preserved from target"
has_not "$A/base/deployment.yaml"  "image: image-a:v2.0.0"            "source image tag NOT copied"
has_not "$A/base/deployment.yaml"  "image: source-image"              "source image name NOT present"
has     "$A/base/deployment.yaml"  "NEW_FEATURE"                      "new env var added from source"
has     "$A/base/deployment.yaml"  "serviceAccountName: sa-a"         "service account substituted"
has     "$A/base/deployment.yaml"  "namespace: ns-a"                  "namespace substituted"

# ── app-a: Deletion (D) ───────────────────────────────────────────────────────
section "app-a  File deletion"
absent  "$A/base/old-feature.yaml"  "old-feature.yaml deleted"

# ── app-a: New file addition (A) with filename substitution ──────────────────
section "app-a  New file — filename substituted"
# source-app-internal-svc.yaml → app-a-internal-svc.yaml
absent  "$A/overlays/dev/source-app-internal-svc.yaml"  "source filename not present"
exists  "$A/overlays/dev/app-a-internal-svc.yaml"       "filename with app-a substitution exists"
has     "$A/overlays/dev/app-a-internal-svc.yaml"  "name: app-a-internal"   "service name substituted in content"
has     "$A/overlays/dev/app-a-internal-svc.yaml"  "namespace: ns-a"        "namespace substituted in new file"

# ── app-a: Rename (R) with filename substitution ─────────────────────────────
section "app-a  File rename — filename substituted"
# source-app-configmap-v1.yaml → source-app-configmap-v2.yaml in source
# = app-a-configmap-v1.yaml   → app-a-configmap-v2.yaml   in target
absent  "$A/overlays/dev/app-a-configmap-v1.yaml"  "old filename removed after rename"
absent  "$A/overlays/dev/source-app-configmap-v2.yaml"  "source filename not present after rename"
exists  "$A/overlays/dev/app-a-configmap-v2.yaml"  "renamed file at app-a path exists"
has     "$A/overlays/dev/app-a-configmap-v2.yaml"  "VERSION: v2"       "content updated after rename"
has     "$A/overlays/dev/app-a-configmap-v2.yaml"  "FEATURE_FLAG: new-flag"  "renamed file content correct"
has     "$A/overlays/dev/app-a-configmap-v2.yaml"  "namespace: ns-a"   "namespace substituted in renamed file"

# ── app-a: SealedSecret copy (A) ─────────────────────────────────────────────
section "app-a  SealedSecret copy — target's own secret used"
# staging/sealed-secret.yaml added in source (same metadata.name as dev one)
# → should copy app-a's dev sealed secret to staging, keep app-a encrypted values
exists  "$A/overlays/staging/sealed-secret.yaml"  "staging sealed secret created"
has     "$A/overlays/staging/sealed-secret.yaml"  "name: app-a-db-credentials"        "secret name substituted"
has     "$A/overlays/staging/sealed-secret.yaml"  "namespace: ns-a"                   "namespace substituted"
has     "$A/overlays/staging/sealed-secret.yaml"  "AppAClusterEncryptedPassword=="     "app-a encrypted values preserved"
has_not "$A/overlays/staging/sealed-secret.yaml"  "SourceStagingEncryptedPassword=="   "source staging secret NOT used"
has_not "$A/overlays/staging/sealed-secret.yaml"  "SourceEncryptedPassword=="          "source dev secret NOT used"

# ── app-b: ConfigMap (M) ─────────────────────────────────────────────────────
section "app-b  ConfigMap — substitutions and protected key"
has     "$B/base/configmap.yaml"  "APP_SETTING: updated-value"   "non-protected key updated in app-b"
has     "$B/base/configmap.yaml"  "NEW_SETTING: new-feature-enabled"  "new key added in app-b"
has     "$B/base/configmap.yaml"  "DATABASE_URL: app-b-postgres.ns-b.svc.cluster.local"  "protected DATABASE_URL preserved in app-b"
has_not "$B/base/configmap.yaml"  "DATABASE_URL: changed-db.internal"  "source DATABASE_URL not in app-b"
has     "$B/base/configmap.yaml"  "SERVICE_NAME: app-b-service"  "app-b service name substituted"

# ── app-b: Deployment (M) ────────────────────────────────────────────────────
section "app-b  Deployment — image tag preserved"
has     "$B/base/deployment.yaml"  "image: image-b:app-b-release-2.1.0"  "image tag preserved in app-b"
has     "$B/base/deployment.yaml"  "NEW_FEATURE"                          "new env var added in app-b"
has     "$B/base/deployment.yaml"  "serviceAccountName: sa-b"             "app-b service account"

# ── app-b: Deletion ───────────────────────────────────────────────────────────
section "app-b  File deletion"
absent  "$B/base/old-feature.yaml"  "old-feature.yaml deleted from app-b"

# ── app-b: New file with filename substitution ───────────────────────────────
section "app-b  New file — filename substituted"
absent  "$B/overlays/dev/source-app-internal-svc.yaml"  "source filename not in app-b"
exists  "$B/overlays/dev/app-b-internal-svc.yaml"       "filename with app-b substitution"
has     "$B/overlays/dev/app-b-internal-svc.yaml"  "name: app-b-internal"  "content substituted in app-b"
has     "$B/overlays/dev/app-b-internal-svc.yaml"  "namespace: ns-b"       "namespace correct in app-b"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}────────────────────────────────────────${NC}"
TOTAL=$(( PASS + FAIL ))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All $TOTAL tests passed${NC}"
else
  echo -e "${GREEN}$PASS passed${NC}  ${RED}${BOLD}$FAIL failed${NC}  (of $TOTAL)"
fi
echo -e "${BOLD}────────────────────────────────────────${NC}"
[[ $FAIL -eq 0 ]]
