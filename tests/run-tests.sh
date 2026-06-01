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
# has_stage3 REPO REL_PATH PATTERN MSG — checks git stage 3 (theirs/right panel)
has_stage3() {
  local _s3
  _s3=$(git -C "$1" cat-file blob ":3:$2" 2>/dev/null || true)
  echo "$_s3" | grep -qF -- "$3" 2>/dev/null && ok "$4" || fail "$4  [missing '$3' in stage 3:$2]"
}

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
git config --global user.email              "test@sync-deploy.test"
git config --global user.name              "Sync-Deploy Test"
git config --global commit.gpgsign         false
git config --global tag.gpgsign            false
git config --global init.defaultBranch     main
git config --global advice.addIgnoredFile  false

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
  mkdir -p base overlays/dev services/environment/teamscope services/environment/enva services/environment/envb

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
images:
  - name: source-image
    newTag: v1.0.0
EOF

  cat > services/environment/teamscope/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - teamscope-only.yaml
configMapGenerator:
  - name: source-app-teamscope
    literals:
      - MARKER=teamscope-v1
EOF

  cat > services/environment/enva/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - enva-only.yaml
configMapGenerator:
  - name: source-app-enva
    literals:
      - MARKER=enva-source
EOF

  cat > services/environment/envb/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - envb-only.yaml
configMapGenerator:
  - name: source-app-envb
    literals:
      - MARKER=envb-source
EOF

  mkdir -p services/environment/teamscope/default \
           services/environment/vs-ont/default \
           services/environment/vs-tst/default

  cat > services/environment/teamscope/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: source-app-teamscope-default
    literals:
      - MARKER=teamscope-default-v1
      - ENV=teamscope
EOF

  cat > services/environment/vs-ont/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: source-app-vs-ont-default
    literals:
      - MARKER=vs-ont-default-v1
      - ENV=vs-ont
EOF

  cat > services/environment/vs-tst/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: source-app-vs-tst-default
    literals:
      - MARKER=vs-tst-default-v1
      - ENV=vs-tst
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

  # M: kustomization.yaml — update resources reference v1→v2, bump image tag
  cat > overlays/dev/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - sealed-secret.yaml
  - source-app-configmap-v2.yaml
images:
  - name: source-image
    newTag: v2.0.0
EOF

  # M: teamscope env kustomization — path_substitution maps this to enva/envb.
  # Targets must use their matching source env file, not this teamscope file.
  cat > services/environment/teamscope/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - teamscope-only.yaml
  - teamscope-new.yaml
configMapGenerator:
  - name: source-app-teamscope
    literals:
      - MARKER=teamscope-v2
EOF

  # M: env/*/default/kustomization.yaml — each updated with a distinct v2 marker
  cat > services/environment/teamscope/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: source-app-teamscope-default
    literals:
      - MARKER=teamscope-default-v2
      - ENV=teamscope
EOF

  cat > services/environment/vs-ont/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: source-app-vs-ont-default
    literals:
      - MARKER=vs-ont-default-v2
      - ENV=vs-ont
EOF

  cat > services/environment/vs-tst/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: source-app-vs-tst-default
    literals:
      - MARKER=vs-tst-default-v2
      - ENV=vs-tst
EOF

  # M: dev sealed-secret — modified in source (must NOT be synced to target)
  cat > overlays/dev/sealed-secret.yaml <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: source-app-db-credentials
  namespace: source-namespace
spec:
  encryptedData:
    password: ModifiedSourceEncryptedPassword==
    username: ModifiedSourceEncryptedUsername==
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

  # A: staging overlay — truly new sealed secret (unique metadata.name, no copy)
  cat > overlays/staging/source-app-unique-secret.yaml <<'EOF'
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: source-app-unique-secret
  namespace: source-namespace
spec:
  encryptedData:
    api_key: SourceUniqueEncryptedValue==
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
  mkdir -p base overlays/dev services/environment/teamscope services/environment/enva services/environment/envb

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
images:
  - name: image-a
    newTag: app-a-custom-v1.5.0
EOF

  cat > services/environment/teamscope/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - teamscope-only.yaml
configMapGenerator:
  - name: app-a-teamscope
    literals:
      - MARKER=teamscope-v1
EOF

  cat > services/environment/enva/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - enva-target.yaml
configMapGenerator:
  - name: app-a-enva
    literals:
      - MARKER=app-a-enva-target
EOF

  cat > services/environment/envb/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - envb-only.yaml
configMapGenerator:
  - name: app-a-envb
    literals:
      - MARKER=envb-v1-app-a
EOF

  mkdir -p services/environment/teamscope/default \
           services/environment/vs-ont/default \
           services/environment/vs-tst/default

  cat > services/environment/teamscope/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: app-a-teamscope-default
    literals:
      - MARKER=teamscope-default-v1
      - ENV=teamscope
EOF

  cat > services/environment/vs-ont/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: app-a-vs-ont-default
    literals:
      - MARKER=vs-ont-default-v1
      - ENV=vs-ont
EOF

  cat > services/environment/vs-tst/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: app-a-vs-tst-default
    literals:
      - MARKER=vs-tst-default-v1
      - ENV=vs-tst
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
  mkdir -p base services/environment/teamscope services/environment/enva services/environment/envb

  cat > services/environment/teamscope/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - teamscope-only.yaml
configMapGenerator:
  - name: app-b-teamscope
    literals:
      - MARKER=teamscope-v1
EOF

  cat > services/environment/enva/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - enva-only.yaml
configMapGenerator:
  - name: app-b-enva
    literals:
      - MARKER=enva-v1-app-b
EOF

  cat > services/environment/envb/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - envb-only.yaml
configMapGenerator:
  - name: app-b-envb
    literals:
      - MARKER=envb-v1-app-b
EOF

  mkdir -p services/environment/teamscope/default \
           services/environment/vs-ont/default \
           services/environment/vs-tst/default

  cat > services/environment/teamscope/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: app-b-teamscope-default
    literals:
      - MARKER=teamscope-default-v1
      - ENV=teamscope
EOF

  cat > services/environment/vs-ont/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: app-b-vs-ont-default
    literals:
      - MARKER=vs-ont-default-v1
      - ENV=vs-ont
EOF

  cat > services/environment/vs-tst/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: app-b-vs-tst-default
    literals:
      - MARKER=vs-tst-default-v1
      - ENV=vs-tst
EOF

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
# TARGET REPO: app-c  (testspace/app-c-deploy)
# Starts with ONLY teamscope/default — vs-ont/default and vs-tst/default are
# absent.  After sync these must be created from scratch with substitutions
# applied (source-app → app-c).  This is the real-world "brand new target
# directory" scenario the user described.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-c-deploy"

app_c_initial() {
  mkdir -p base services/environment/teamscope services/environment/enva \
           services/environment/envb services/environment/teamscope/default

  cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-c
  namespace: ns-c
spec:
  selector:
    matchLabels:
      app: app-c
  template:
    metadata:
      labels:
        app: app-c
    spec:
      serviceAccountName: sa-c
      containers:
        - name: app-c
          image: image-c:app-c-v1.0.0
          env:
            - name: APP_NAME
              value: app-c
            - name: PAAS_PROJECT
              value: app-c-paas-project
EOF

  cat > base/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-c-config
  namespace: ns-c
data:
  DATABASE_URL: app-c-postgres.ns-c.svc.cluster.local
  APP_SETTING: original-value
  SERVICE_NAME: app-c-service
EOF

  cat > base/old-feature.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-c-old-config
  namespace: ns-c
data:
  LEGACY_SETTING: old-value
EOF

  cat > services/environment/teamscope/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - teamscope-only.yaml
configMapGenerator:
  - name: app-c-teamscope
    literals:
      - MARKER=teamscope-v1
EOF

  cat > services/environment/enva/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: app-c-enva
    literals:
      - MARKER=enva-v1-app-c
EOF

  cat > services/environment/envb/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: app-c-envb
    literals:
      - MARKER=envb-v1-app-c
EOF

  # teamscope/default exists, vs-ont/default and vs-tst/default do NOT
  cat > services/environment/teamscope/default/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: app-c-teamscope-default
    literals:
      - MARKER=teamscope-default-v1
      - ENV=teamscope
EOF
}
with_work "app-c-deploy" "" app_c_initial

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-d  (testspace/app-d-deploy)  [spare target with deploy section]
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-d-deploy"

app_d_initial() {
  mkdir -p base

  cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-d
  namespace: ns-d
spec:
  selector:
    matchLabels:
      app: app-d
  template:
    metadata:
      labels:
        app: app-d
    spec:
      serviceAccountName: sa-d
      containers:
        - name: app-d
          image: image-d:app-d-v1.0.0
          env:
            - name: APP_NAME
              value: app-d
EOF

  cat > base/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-d-config
  namespace: ns-d
data:
  DATABASE_URL: app-d-postgres.ns-d.svc.cluster.local
  APP_SETTING: original-value
EOF

  cat > base/old-feature.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-d-old-config
  namespace: ns-d
data:
  LEGACY_SETTING: old-value
EOF
}
with_work "app-d-deploy" "" app_d_initial

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-g  (testspace/app-g-deploy)
# No path_substitutions in config — auto-derive from app_name must work.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-g-deploy"

app_g_initial() {
  mkdir -p base

  cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-g
  namespace: ns-g
spec:
  selector:
    matchLabels:
      app: app-g
  template:
    metadata:
      labels:
        app: app-g
    spec:
      serviceAccountName: sa-g
      containers:
        - name: app-g
          image: image-g:app-g-v1.0.0
          env:
            - name: APP_NAME
              value: app-g
            - name: PAAS_PROJECT
              value: app-g-paas-project
EOF

  cat > base/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-g-config
  namespace: ns-g
data:
  DATABASE_URL: app-g-postgres.ns-g.svc.cluster.local
  APP_SETTING: original-value
  SERVICE_NAME: app-g-service
EOF

  cat > base/old-feature.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-g-old-config
  namespace: ns-g
data:
  LEGACY_SETTING: old-value
EOF
}
with_work "app-g-deploy" "" app_g_initial

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-e  (testspace/app-e-deploy)  [copy mode scenario]
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-e-deploy"

app_e_initial() {
  mkdir -p base

  cat > base/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-e-config
  namespace: ns-e
data:
  DATABASE_URL: app-e-postgres.ns-e.svc.cluster.local
  APP_SETTING: original-value
  SERVICE_NAME: app-e-service
EOF

  cat > base/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-e
  namespace: ns-e
spec:
  selector:
    matchLabels:
      app: app-e
  template:
    metadata:
      labels:
        app: app-e
    spec:
      serviceAccountName: sa-e
      containers:
        - name: app-e
          image: image-e:app-e-LOCAL-TAG-2.5.0
          env:
            - name: APP_NAME
              value: app-e
EOF

  # This file is ONLY in app-e target, not in source — must be deleted in copy mode
  cat > base/extra-target-only.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-e-extra
  namespace: ns-e
data:
  EXTRA: only-in-target
EOF
}
with_work "app-e-deploy" "" app_e_initial

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE APP REPO  (testspace/source-app-repo)  [app-f scenario]
# v1.0.0 → initial state (Maven project)
# v1.1.0 → changes: M Service.java, M pom.xml, A NewHelper.java, D OldUtil.java
# ─────────────────────────────────────────────────────────────────────────────
make_bare "source-app-repo"

source_app_v1() {
  mkdir -p "source-app-core/src/main/java/com/source/app"
  mkdir -p "source-app-core/src/main/resources"

  cat > pom.xml <<'EOF'
<project>
  <groupId>com.source.app</groupId>
  <artifactId>source-app</artifactId>
  <version>1.0.0</version>
</project>
EOF

  cat > "source-app-core/pom.xml" <<'EOF'
<project>
  <artifactId>source-app-core</artifactId>
  <version>1.0.0</version>
</project>
EOF

  cat > "source-app-core/src/main/java/com/source/app/Service.java" <<'EOF'
package com.source.app;
public class Service {
  public String greet() { return "hello from source-app"; }
}
EOF

  cat > "source-app-core/src/main/java/com/source/app/OldUtil.java" <<'EOF'
package com.source.app;
public class OldUtil {}
EOF

  cat > "source-app-core/src/main/resources/application.properties" <<'EOF'
app.name=source-app
app.version=1.0.0
EOF
}
with_work "source-app-repo" "v1.0.0" source_app_v1

source_app_v2() {
  # M: Service.java — add version() method
  cat > "source-app-core/src/main/java/com/source/app/Service.java" <<'EOF'
package com.source.app;
public class Service {
  public String greet() { return "hello from source-app"; }
  public String version() { return "1.1.0"; }
}
EOF

  # M: pom.xml — add description
  cat > pom.xml <<'EOF'
<project>
  <groupId>com.source.app</groupId>
  <artifactId>source-app</artifactId>
  <version>1.0.0</version>
  <description>Updated description for source-app</description>
</project>
EOF

  # A: NewHelper.java added
  cat > "source-app-core/src/main/java/com/source/app/NewHelper.java" <<'EOF'
package com.source.app;
public class NewHelper { public static String help() { return "source-app helper"; } }
EOF

  # D: OldUtil.java deleted
  rm -f "source-app-core/src/main/java/com/source/app/OldUtil.java"
}
with_work "source-app-repo" "v1.1.0" source_app_v2

# ─────────────────────────────────────────────────────────────────────────────
# TARGET APP REPO: app-f  (testspace/app-f-app)
# Mirrors source v1.0.0 structure but with substitutions applied
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-f-app"

app_f_initial() {
  mkdir -p "app-f-core/src/main/java/com/app/f"
  mkdir -p "app-f-core/src/main/resources"

  cat > pom.xml <<'EOF'
<project>
  <groupId>com.app.f</groupId>
  <artifactId>app-f</artifactId>
  <version>1.0.0</version>
</project>
EOF

  cat > "app-f-core/pom.xml" <<'EOF'
<project>
  <artifactId>app-f-core</artifactId>
  <version>1.0.0</version>
</project>
EOF

  cat > "app-f-core/src/main/java/com/app/f/Service.java" <<'EOF'
package com.app.f;
public class Service {
  public String greet() { return "hello from app-f"; }
  public String localExtra() { return "only in app-f"; }
}
EOF

  cat > "app-f-core/src/main/java/com/app/f/OldUtil.java" <<'EOF'
package com.app.f;
public class OldUtil {}
EOF

  cat > "app-f-core/src/main/resources/application.properties" <<'EOF'
app.name=app-f
app.version=1.0.0
EOF
}
with_work "app-f-app" "" app_f_initial

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE KV REPO  (testspace/source-kv-repo)
# Minimal app repo exercising the two global-key-search scenarios:
#   app.properties — version on line 1, no context before → global search
#   pom.xml        — version inside <parent> block
# ─────────────────────────────────────────────────────────────────────────────
make_bare "source-kv-repo"

source_kv_v1() {
  # app.version is line 1 → unified diff has zero context-before lines
  cat > app.properties <<'EOF'
app.version=1.0.0
app.name=source-app
EOF

  # pom.xml: <version> nested inside <parent>
  cat > pom.xml <<'EOF'
<project>
  <parent>
    <groupId>com.source</groupId>
    <version>1.0.0</version>
  </parent>
  <groupId>com.source.app</groupId>
  <artifactId>source-app</artifactId>
</project>
EOF
}
with_work "source-kv-repo" "v1.0.0" source_kv_v1

source_kv_v2() {
  # Bump version in both files
  cat > app.properties <<'EOF'
app.version=1.1.0
app.name=source-app
EOF

  cat > pom.xml <<'EOF'
<project>
  <parent>
    <groupId>com.source</groupId>
    <version>1.1.0</version>
  </parent>
  <groupId>com.source.app</groupId>
  <artifactId>source-app</artifactId>
</project>
EOF
}
with_work "source-kv-repo" "v1.1.0" source_kv_v2

# ─────────────────────────────────────────────────────────────────────────────
# TARGET KV REPO: app-h  (testspace/app-h-kv)
# Two files that exercise distinct fallback paths:
#
#   app.properties
#     app.version=2.5.0  ← differs from base 1.0.0, patch rejects hunk.
#     No context before version line (line 1) → cb_count=0 → global search.
#     Expected: global key-search finds app.version= and updates to 1.1.0.
#
#   pom.xml
#     Has NO <parent> block.  The diff targets <parent>/<version>.
#     Global search finds two <version> elements, but NEITHER is inside
#     <parent> → container check rejects both → conflict markers written,
#     project <version>3.0.0</version> is preserved unchanged.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-h-kv"

app_h_initial() {
  cat > app.properties <<'EOF'
app.version=2.5.0
app.name=app-h
EOF

  # No <parent> block; has project version and a dependency version
  cat > pom.xml <<'EOF'
<project>
  <groupId>com.app.h</groupId>
  <artifactId>app-h</artifactId>
  <version>3.0.0</version>
  <dependencies>
    <dependency>
      <groupId>com.other</groupId>
      <artifactId>lib</artifactId>
      <version>5.0.0</version>
    </dependency>
  </dependencies>
</project>
EOF
}
with_work "app-h-kv" "" app_h_initial

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE INJ REPO  (testspace/source-inj-repo)
# Exercises two new fallback paths:
#   app.xml   — del_count=1, add_count=2 (unequal counts) with context that
#               doesn't match target → try_inject_by_key places conflict at
#               correct <mode> line instead of appending to file end.
#   legacy.xml — pure deletion hunk (add_count=0) whose context doesn't match
#               target but exact del-line value matches → try_apply_global
#               auto-deletes the line cleanly.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "source-inj-repo"

source_inj_v1() {
  cat > app.xml <<'EOF'
<application>
  <context>original</context>
  <mode>simple</mode>
</application>
EOF

  cat > legacy.xml <<'EOF'
<legacy>
  <section-origin>from-source</section-origin>
  <item>remove-this</item>
</legacy>
EOF
}
with_work "source-inj-repo" "v1.0.0" source_inj_v1

source_inj_v2() {
  # mode: one line becomes two (del_count=1, add_count=2)
  cat > app.xml <<'EOF'
<application>
  <context>original</context>
  <mode>advanced</mode>
  <plugin>enabled</plugin>
</application>
EOF

  # legacy.xml: pure deletion of <item> line (add_count=0)
  cat > legacy.xml <<'EOF'
<legacy>
  <section-origin>from-source</section-origin>
</legacy>
EOF
}
with_work "source-inj-repo" "v1.1.0" source_inj_v2

# ─────────────────────────────────────────────────────────────────────────────
# TARGET INJ REPO: app-l  (testspace/app-l-inj)
# app.xml  — context line differs (customized vs original) so find_loc fails.
#            The <mode> key IS present → try_inject_by_key places conflict there.
# legacy.xml — context line differs but <item>remove-this</item> is verbatim
#              from source_A → try_apply_global (exact_del) auto-deletes it.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-l-inj"

app_l_initial() {
  # <context> value differs from source → patch context won't match
  cat > app.xml <<'EOF'
<application>
  <context>customized</context>
  <mode>enterprise</mode>
</application>
EOF

  # <section-diff> differs from source context, but <item> is verbatim
  cat > legacy.xml <<'EOF'
<legacy>
  <section-diff>different-context</section-diff>
  <item>remove-this</item>
</legacy>
EOF
}
with_work "app-l-inj" "" app_l_initial

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE DUP REPO  (testspace/source-dup-repo)
# K8s-style YAML with duplicate keys (multiple - name:/value: env-var pairs)
# and Maven pom.xml with duplicate <version>, <groupId>, <artifactId> tags.
# v1.0.0 → initial state
# v1.1.0 → APP_SETTING changed, NEW_FEATURE added, parent bumped, lib-b bumped,
#           lib-c added
# ─────────────────────────────────────────────────────────────────────────────
make_bare "source-dup-repo"

source_dup_v1() {
  cat > deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: source-app
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: source-app
        image: source-image:v1.0.0
        env:
        - name: DATABASE_URL
          value: localhost
        - name: APP_SETTING
          value: original-value
        - name: LOG_LEVEL
          value: debug
EOF

  cat > pom.xml <<'EOF'
<project>
  <groupId>com.source.dup</groupId>
  <artifactId>source-app</artifactId>
  <version>1.0.0</version>
  <parent>
    <groupId>com.source.parent</groupId>
    <artifactId>parent-pom</artifactId>
    <version>2.0.0</version>
  </parent>
  <dependencies>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>lib-a</artifactId>
      <version>3.0.0</version>
    </dependency>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>lib-b</artifactId>
      <version>1.0.0</version>
    </dependency>
  </dependencies>
</project>
EOF
}
with_work "source-dup-repo" "v1.0.0" source_dup_v1

source_dup_v2() {
  cat > deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: source-app
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: source-app
        image: source-image:v1.1.0
        env:
        - name: DATABASE_URL
          value: localhost
        - name: APP_SETTING
          value: updated-value
        - name: LOG_LEVEL
          value: debug
        - name: NEW_FEATURE
          value: enabled
EOF

  cat > pom.xml <<'EOF'
<project>
  <groupId>com.source.dup</groupId>
  <artifactId>source-app</artifactId>
  <version>1.0.0</version>
  <parent>
    <groupId>com.source.parent</groupId>
    <artifactId>parent-pom</artifactId>
    <version>2.1.0</version>
  </parent>
  <dependencies>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>lib-a</artifactId>
      <version>3.0.0</version>
    </dependency>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>lib-b</artifactId>
      <version>1.5.0</version>
    </dependency>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>lib-c</artifactId>
      <version>2.5.0</version>
    </dependency>
  </dependencies>
</project>
EOF
}
with_work "source-dup-repo" "v1.1.0" source_dup_v2

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-k  (testspace/app-k) — Kubernetes deployment with
# target customizations: replicas=3, custom image, custom env values,
# plus an extra target-only env var EXTRA_CONFIG.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-k"

app_k_initial() {
  cat > deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-k
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: app-k
        image: app-k-image:prod
        env:
        - name: DATABASE_URL
          value: prod-db
        - name: APP_SETTING
          value: custom-value
        - name: LOG_LEVEL
          value: warn
        - name: EXTRA_CONFIG
          value: target-only
EOF
}
with_work "app-k" "" app_k_initial

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-m  (testspace/app-m) — Maven pom.xml with target
# customizations: own groupId/artifactId, no parent block, own lib-a version,
# plus a target-only dependency lib-d.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-m"

app_m_initial() {
  cat > pom.xml <<'EOF'
<project>
  <groupId>com.app.m</groupId>
  <artifactId>app-m</artifactId>
  <version>4.0.0</version>
  <dependencies>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>lib-a</artifactId>
      <version>5.0.0</version>
    </dependency>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>lib-b</artifactId>
      <version>1.0.0</version>
    </dependency>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>lib-d</artifactId>
      <version>3.0.0</version>
    </dependency>
  </dependencies>
</project>
EOF
}
with_work "app-m" "" app_m_initial

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE DEL REPO  (testspace/source-del-repo)
# Minimal YAML with env-var blocks — tests that a key deleted in v2 does NOT
# appear in stage3 even when target still contains that key.
# v1.0.0 → KEY_A + KEY_B
# v1.1.0 → KEY_A value changed, KEY_B DELETED, KEY_C ADDED
# ─────────────────────────────────────────────────────────────────────────────
make_bare "source-del-repo"

source_del_v1() {
  cat > config.yaml <<'EOF'
app:
  env:
  - name: KEY_A
    value: val-a
  - name: KEY_B
    value: val-b
EOF
}
with_work "source-del-repo" "v1.0.0" source_del_v1

source_del_v2() {
  cat > config.yaml <<'EOF'
app:
  env:
  - name: KEY_A
    value: val-a-new
  - name: KEY_C
    value: val-c
EOF
}
with_work "source-del-repo" "v1.1.0" source_del_v2

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-del  (testspace/app-del)
# Has KEY_A (custom value), KEY_B (target still holds it), KEY_D (target-only)
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-del"

app_del_initial() {
  cat > config.yaml <<'EOF'
app:
  env:
  - name: KEY_A
    value: prod-a
  - name: KEY_B
    value: prod-b
  - name: KEY_D
    value: target-only
EOF
}
with_work "app-del" "" app_del_initial

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE PREKEY REPO  (testspace/source-prekey-repo)
# Regression for pre-key keyless anchor mismatch: theirs_last_p was uninitialized
# ("") while tgt_last_p was 0, so comments BEFORE the first keyed line were
# stored under anchor ("",0) but looked up under ("",""), causing them to be
# dropped from stage3 and appear displaced.
# v1.0.0: leading comment + <version.a> unchanged, <version.b> val
# v1.1.0: same comment + <version.a> unchanged, <version.b> bumped
# ─────────────────────────────────────────────────────────────────────────────
make_bare "source-prekey-repo"

source_prekey_v1() {
  cat > versions.xml <<'EOF'
<!-- managed versions -->
<version.a>1.0.0</version.a>
<version.b>2.0.0</version.b>
EOF
}
with_work "source-prekey-repo" "v1.0.0" source_prekey_v1

source_prekey_v2() {
  cat > versions.xml <<'EOF'
<!-- managed versions -->
<version.a>1.0.0</version.a>
<version.b>2.1.0</version.b>
EOF
}
with_work "source-prekey-repo" "v1.1.0" source_prekey_v2

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-prekey  (testspace/app-prekey)
# Same structure as source v1 — target has no customisations so the pre-key
# comment must pass through unchanged and version.b must show as highlighted.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-prekey"

app_prekey_initial() {
  cat > versions.xml <<'EOF'
<!-- managed versions -->
<version.a>1.0.0</version.a>
<version.b>2.0.0</version.b>
EOF
}
with_work "app-prekey" "" app_prekey_initial

# ─────────────────────────────────────────────────────────────────────────────
# SOURCE JENKINSFILE REPO  (testspace/source-jenkins-repo)
# Regression for linekey() false-positive on Groovy/shell code files:
# lines like "choice(choices: [...])" and "// URL: https://..." contain ':' and
# were being parsed as YAML keys, setting tgt_had_keys=1 and causing the keyed
# matching logic to scramble keyless Jenkinsfile content in stage3.
# v1.0.0: Jenkinsfile with choice() parameters and a cron comment block
# v1.1.0: one cron comment line changed ("# Old comment:" → "# New comment:")
# ─────────────────────────────────────────────────────────────────────────────
make_bare "source-jenkins-repo"

source_jenkins_v1() {
  cat > Jenkinsfile <<'EOF'
/**********************************************/
pipeline {
    agent { node { label 'master-node' } }

    parameters {
        choice(choices: ['build','deploy'], description: 'Selecteer optie: ', name: 'Optie')
    }

    triggers {
        // Bekijk cron opties op: https://crontab.guru
        parameterizedCron(env.BRANCH_NAME == 'develop' ? '''
            # Old comment: run every wednesday
            # 0 22 * * 3 % Optie=build;
           ''' : '')
    }
}
EOF
}
with_work "source-jenkins-repo" "v1.0.0" source_jenkins_v1

source_jenkins_v2() {
  cat > Jenkinsfile <<'EOF'
/**********************************************/
pipeline {
    agent { node { label 'master-node' } }

    parameters {
        choice(choices: ['build','deploy'], description: 'Selecteer optie: ', name: 'Optie')
    }

    triggers {
        // Bekijk cron opties op: https://crontab.guru
        parameterizedCron(env.BRANCH_NAME == 'develop' ? '''
            # New comment: run every thursday
            # 0 22 * * 4 % Optie=build;
           ''' : '')
    }
}
EOF
}
with_work "source-jenkins-repo" "v1.1.0" source_jenkins_v2

# ─────────────────────────────────────────────────────────────────────────────
# TARGET REPO: app-jenkins  (testspace/app-jenkins)
# Same Jenkinsfile as source v1 (target has no customisations).
# Stage3 must: preserve the header comment, preserve choice() lines unchanged,
# and highlight only the two changed cron lines.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "app-jenkins"

app_jenkins_initial() {
  cat > Jenkinsfile <<'EOF'
/**********************************************/
pipeline {
    agent { node { label 'master-node' } }

    parameters {
        choice(choices: ['build','deploy'], description: 'Selecteer optie: ', name: 'Optie')
    }

    triggers {
        // Bekijk cron opties op: https://crontab.guru
        parameterizedCron(env.BRANCH_NAME == 'develop' ? '''
            # Old comment: run every wednesday
            # 0 22 * * 3 % Optie=build;
           ''' : '')
    }
}
EOF
}
with_work "app-jenkins" "" app_jenkins_initial

# ─────────────────────────────────────────────────────────────────────────────
# Generate test repos.json pointing to our local testspace/ repos
# Uses the new grouped "apps" structure
# ─────────────────────────────────────────────────────────────────────────────
cat > "$T/repos.test.json" <<'EOF'
{
  "pr": {
    "base_branch":  "main",
    "title_prefix": "chore(sync): "
  },
  "protected_configmap_keys": ["DATABASE_URL"],
  "apps": [
    {
      "name": "source",
      "deploy": {
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
      "app": {
        "repo": "testspace/source-app-repo",
        "substitutions": {
          "app_name":     "source-app",
          "java_package": "com.source.app",
          "java_path":    "com/source/app"
        }
      }
    },
    {
      "name": "app-a",
      "deploy": {
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
      }
    },
    {
      "name": "app-b",
      "deploy": {
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
    },
    {
      "name": "app-c",
      "deploy": {
        "repo": "testspace/app-c-deploy",
        "substitutions": {
          "service_name":    "app-c-service",
          "app_name":        "app-c",
          "paas_name":       "app-c-paas-project",
          "namespace":       "ns-c",
          "environment":     "staging",
          "service_account": "sa-c",
          "image_name":      "image-c",
          "context_url":     "app-c.example.com",
          "health_url":      "app-c.example.com/actuator/health"
        }
      }
    },
    {
      "name": "app-d",
      "deploy": {
        "repo": "testspace/app-d-deploy",
        "substitutions": {
          "service_name":    "app-d-service",
          "app_name":        "app-d",
          "paas_name":       "app-d-paas-project",
          "namespace":       "ns-d",
          "environment":     "staging",
          "service_account": "sa-d",
          "image_name":      "image-d",
          "context_url":     "app-d.example.com",
          "health_url":      "app-d.example.com/actuator/health"
        }
      }
    },
    {
      "name": "app-e",
      "deploy": {
        "repo": "testspace/app-e-deploy",
        "substitutions": {
          "service_name":    "app-e-service",
          "app_name":        "app-e",
          "paas_name":       "app-e-paas-project",
          "namespace":       "ns-e",
          "environment":     "staging",
          "service_account": "sa-e",
          "image_name":      "image-e",
          "context_url":     "app-e.example.com",
          "health_url":      "app-e.example.com/actuator/health"
        }
      }
    },
    {
      "name": "app-g",
      "deploy": {
        "repo": "testspace/app-g-deploy",
        "substitutions": {
          "service_name":    "app-g-service",
          "app_name":        "app-g",
          "paas_name":       "app-g-paas-project",
          "namespace":       "ns-g",
          "environment":     "staging",
          "service_account": "sa-g",
          "image_name":      "image-g"
        }
      }
    },
    {
      "name": "app-f",
      "app": {
        "repo": "testspace/app-f-app",
        "substitutions": {
          "app_name":     "app-f",
          "java_package": "com.app.f",
          "java_path":    "com/app/f"
        }
      }
    },
    {
      "name": "source-kv",
      "app": {
        "repo": "testspace/source-kv-repo",
        "substitutions": {
          "app_name":     "source-app",
          "java_package": "com.source.app",
          "java_path":    "com/source/app"
        }
      }
    },
    {
      "name": "app-h",
      "app": {
        "repo": "testspace/app-h-kv",
        "substitutions": {
          "app_name":     "app-h",
          "java_package": "com.app.h",
          "java_path":    "com/app/h"
        }
      }
    },
    {
      "name": "source-inj",
      "app": {
        "repo": "testspace/source-inj-repo",
        "substitutions": {
          "app_name":     "source-inj",
          "java_package": "com.source.inj",
          "java_path":    "com/source/inj"
        }
      }
    },
    {
      "name": "app-l",
      "app": {
        "repo": "testspace/app-l-inj",
        "substitutions": {
          "app_name":     "app-l",
          "java_package": "com.app.l",
          "java_path":    "com/app/l"
        }
      }
    },
    {
      "name": "source-dup",
      "app": {
        "repo": "testspace/source-dup-repo",
        "substitutions": {
          "app_name":     "source-app",
          "java_package": "com.source.dup",
          "java_path":    "com/source/dup"
        }
      }
    },
    {
      "name": "app-k",
      "app": {
        "repo": "testspace/app-k",
        "substitutions": {
          "app_name":     "app-k",
          "java_package": "com.app.k",
          "java_path":    "com/app/k"
        }
      }
    },
    {
      "name": "app-m",
      "app": {
        "repo": "testspace/app-m",
        "substitutions": {
          "app_name":     "app-m",
          "java_package": "com.app.m",
          "java_path":    "com/app/m"
        }
      }
    },
    {
      "name": "source-del",
      "app": {
        "repo": "testspace/source-del-repo",
        "substitutions": {
          "app_name":     "source-del",
          "java_package": "com.source.del",
          "java_path":    "com/source/del"
        }
      }
    },
    {
      "name": "app-del",
      "app": {
        "repo": "testspace/app-del",
        "substitutions": {
          "app_name":     "app-del",
          "java_package": "com.app.del",
          "java_path":    "com/app/del"
        }
      }
    },
    {
      "name": "source-prekey",
      "app": {
        "repo": "testspace/source-prekey-repo",
        "substitutions": {
          "app_name":     "source-prekey",
          "java_package": "com.source.prekey",
          "java_path":    "com/source/prekey"
        }
      }
    },
    {
      "name": "app-prekey",
      "app": {
        "repo": "testspace/app-prekey",
        "substitutions": {
          "app_name":     "app-prekey",
          "java_package": "com.app.prekey",
          "java_path":    "com/app/prekey"
        }
      }
    },
    {
      "name": "source-jenkins",
      "app": {
        "repo": "testspace/source-jenkins-repo",
        "substitutions": {
          "app_name":     "source-jenkins",
          "java_package": "com.source.jenkins",
          "java_path":    "com/source/jenkins"
        }
      }
    },
    {
      "name": "app-jenkins",
      "app": {
        "repo": "testspace/app-jenkins",
        "substitutions": {
          "app_name":     "app-jenkins",
          "java_package": "com.app.jenkins",
          "java_path":    "com/app/jenkins"
        }
      }
    }
  ]
}
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Run the sync  (non-interactive: --from / --to / --targets all explicit)
# Using --source source --type deploy (replaces old --source source-deploy)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (v1.0.0 → v1.1.0, deploy type, all targets)${NC}"
rm -rf "$WORK_DIR"

bash "$SYNC_SCRIPT" \
  --config "$T/repos.test.json" \
  --source source \
  --type   deploy \
  --from   v1.0.0 \
  --to     v1.1.0

# ─────────────────────────────────────────────────────────────────────────────
# Assertions
# ─────────────────────────────────────────────────────────────────────────────
A="$WORK_DIR/app-a"
B="$WORK_DIR/app-b"
C="$WORK_DIR/app-c"

# ── app-a: ConfigMap (M) ──────────────────────────────────────────────────────
section "app-a  ConfigMap — three-way merge"
has_stage3 "$A" "base/configmap.yaml"  "APP_SETTING: updated-value"        "non-protected key in stage 3 right panel"
has_stage3 "$A" "base/configmap.yaml"  "NEW_SETTING: new-feature-enabled"  "new key in stage 3 right panel"
has        "$A/base/configmap.yaml"  "SERVICE_NAME: app-a-service"  "app substitution applied to value"
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
has_stage3 "$A" "base/deployment.yaml"  "NEW_FEATURE"  "new env var in stage 3 right panel"
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
has_stage3 "$B" "base/configmap.yaml"  "APP_SETTING: updated-value"        "non-protected key in stage 3 right panel"
has_stage3 "$B" "base/configmap.yaml"  "NEW_SETTING: new-feature-enabled"  "new key in stage 3 right panel"
has     "$B/base/configmap.yaml"  "DATABASE_URL: app-b-postgres.ns-b.svc.cluster.local"  "protected DATABASE_URL preserved in app-b"
has_not "$B/base/configmap.yaml"  "DATABASE_URL: changed-db.internal"  "source DATABASE_URL not in app-b"
has     "$B/base/configmap.yaml"  "SERVICE_NAME: app-b-service"  "app-b service name substituted"

# ── app-b: Deployment (M) ────────────────────────────────────────────────────
section "app-b  Deployment — image tag preserved"
has     "$B/base/deployment.yaml"  "image: image-b:app-b-release-2.1.0"  "image tag preserved in app-b"
has_stage3 "$B" "base/deployment.yaml"  "NEW_FEATURE"  "new env var in stage 3 right panel"
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

# ── Branch name contains FROM/TO refs and type+mode ──────────────────────────
section "Branch name contains type, mode, FROM and TO refs"
_branch=$(git -C "$WORK_DIR/app-a" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$_branch" == "sync/deploy-diff-from-v1.0.0-to-v1.1.0" ]]; then
  ok "branch is sync/deploy-diff-from-v1.0.0-to-v1.1.0"
else
  fail "expected sync/deploy-diff-from-v1.0.0-to-v1.1.0, got $_branch"
fi
unset _branch

# ── app-a: kustomization.yaml images block — newTag preserved ────────────────
section "app-a  kustomization.yaml — images newTag preserved from target"
has     "$A/overlays/dev/kustomization.yaml"  "newTag: app-a-custom-v1.5.0"  "target newTag preserved"
has_not "$A/overlays/dev/kustomization.yaml"  "newTag: v2.0.0"               "source newTag not copied"
has_not "$A/overlays/dev/kustomization.yaml"  "newTag: v1.0.0"               "base newTag not copied either"
has     "$A/overlays/dev/kustomization.yaml"  "name: image-a"                "image name substituted"
has_stage3 "$A" "overlays/dev/kustomization.yaml"  "app-a-configmap-v2.yaml"  "v2 reference in stage 3 right panel"
has     "$A/overlays/dev/kustomization.yaml"  "app-a-configmap-v1.yaml"      "v1 reference in conflict ours section (click >> to accept v2)"
has_not "$A/overlays/dev/kustomization.yaml"  "source-image"                 "no source-image in kustomization"

# ── app-b: kustomization.yaml — first-time copy, source values used ──────────
section "app-b  kustomization.yaml — first-time copy, source values used"
exists  "$B/overlays/dev/kustomization.yaml"                                  "kustomization.yaml created for app-b"
has     "$B/overlays/dev/kustomization.yaml"  "name: image-b"                "image name substituted in app-b"
has     "$B/overlays/dev/kustomization.yaml"  "newTag: v2.0.0"               "source newTag used for first-time copy"
has     "$B/overlays/dev/kustomization.yaml"  "app-b-configmap-v2.yaml"      "resources reference has app-b naming"
has_not "$B/overlays/dev/kustomization.yaml"  "source-image"                 "no source-image in app-b kustomization"

# ── env kustomization: same dir structure in source and all targets ───────────
# Source modifies teamscope/kustomization.yaml only. All repos share the same
# directory structure (teamscope, enva, envb). No path substitution for env dirs.
# Changes go to the matching dir in every target; other env dirs are untouched.
section "environment kustomization.yaml — same structure, teamscope updated"
exists  "$A/services/environment/teamscope/kustomization.yaml"             "teamscope exists in app-a"
has_stage3 "$A" "services/environment/teamscope/kustomization.yaml"  "MARKER=teamscope-v2"  "teamscope v2 in stage 3 right panel (app-a)"
has     "$A/services/environment/teamscope/kustomization.yaml"  "app-a-teamscope"        "app-a name substituted in teamscope"
has_not "$A/services/environment/teamscope/kustomization.yaml"  "source-app"             "source name not present in app-a teamscope"
has     "$A/services/environment/enva/kustomization.yaml"       "MARKER=app-a-enva-target"  "app-a enva content preserved (not in diff)"
has_not "$A/services/environment/enva/kustomization.yaml"       "MARKER=teamscope-v2"    "teamscope change not bleed into enva"
has     "$A/services/environment/envb/kustomization.yaml"       "MARKER=envb-v1-app-a"   "app-a envb content preserved (not in diff)"
has_not "$A/services/environment/envb/kustomization.yaml"       "MARKER=teamscope-v2"    "teamscope change not bleed into envb"
exists  "$B/services/environment/teamscope/kustomization.yaml"             "teamscope exists in app-b"
has_stage3 "$B" "services/environment/teamscope/kustomization.yaml"  "MARKER=teamscope-v2"  "teamscope v2 in stage 3 right panel (app-b)"
has     "$B/services/environment/teamscope/kustomization.yaml"  "app-b-teamscope"        "app-b name substituted in teamscope"
has_not "$B/services/environment/teamscope/kustomization.yaml"  "source-app"             "source name not present in app-b teamscope"
has     "$B/services/environment/enva/kustomization.yaml"       "MARKER=enva-v1-app-b"   "app-b enva content preserved (not in diff)"
has_not "$B/services/environment/enva/kustomization.yaml"       "MARKER=teamscope-v2"    "teamscope change not bleed into enva in app-b"
has     "$B/services/environment/envb/kustomization.yaml"       "MARKER=envb-v1-app-b"   "app-b envb content preserved (not in diff)"
has_not "$B/services/environment/envb/kustomization.yaml"       "MARKER=teamscope-v2"    "teamscope change not bleed into envb in app-b"

# ── app-a: SealedSecret M (modified) — not synced ────────────────────────────
section "app-a  SealedSecret M (modified) — not synced to target"
has     "$A/overlays/dev/sealed-secret.yaml"  "AppAClusterEncryptedPassword=="     "target sealed secret values unchanged"
has_not "$A/overlays/dev/sealed-secret.yaml"  "ModifiedSourceEncryptedPassword=="  "modified source values not copied"

# ── app-b: SealedSecret M (modified) — no target file created ────────────────
section "app-b  SealedSecret M (modified) — no target file created"
absent  "$B/overlays/dev/sealed-secret.yaml"  "sealed secret M does not create missing target file"

# ── app-b: SealedSecret copy — no matching secret found, encryptedData blanked
section "app-b  SealedSecret copy — no match, encryptedData blanked"
exists  "$B/overlays/staging/sealed-secret.yaml"                                  "staging sealed secret created for app-b"
has     "$B/overlays/staging/sealed-secret.yaml"  "name: app-b-db-credentials"    "secret name substituted"
has     "$B/overlays/staging/sealed-secret.yaml"  "namespace: ns-b"               "namespace substituted"
has_not "$B/overlays/staging/sealed-secret.yaml"  "SourceStagingEncryptedPassword=="  "source values not used"
has     "$B/overlays/staging/sealed-secret.yaml"  "TODO: kubeseal"                "encryptedData blanked with TODO marker"

# ── app-a: SealedSecret new (truly new, not a copy) — encryptedData blanked ──
section "app-a  SealedSecret new (not a copy) — encryptedData blanked"
exists  "$A/overlays/staging/app-a-unique-secret.yaml"                             "truly new sealed secret created"
has     "$A/overlays/staging/app-a-unique-secret.yaml"  "name: app-a-unique-secret"  "unique secret name substituted"
has     "$A/overlays/staging/app-a-unique-secret.yaml"  "namespace: ns-a"            "namespace substituted"
has_not "$A/overlays/staging/app-a-unique-secret.yaml"  "SourceUniqueEncryptedValue=="  "source values not used"
has     "$A/overlays/staging/app-a-unique-secret.yaml"  "TODO: kubeseal"             "encryptedData blanked"

# ── app-b: SealedSecret new (truly new, not a copy) — encryptedData blanked ──
section "app-b  SealedSecret new (not a copy) — encryptedData blanked"
exists  "$B/overlays/staging/app-b-unique-secret.yaml"                             "truly new sealed secret created for app-b"
has     "$B/overlays/staging/app-b-unique-secret.yaml"  "name: app-b-unique-secret"  "unique secret name substituted in app-b"
has_not "$B/overlays/staging/app-b-unique-secret.yaml"  "SourceUniqueEncryptedValue=="  "source values not used in app-b"
has     "$B/overlays/staging/app-b-unique-secret.yaml"  "TODO: kubeseal"             "encryptedData blanked in app-b"

# ── env/*/default — each kustomization copied to same path, own content only ─
section "env default dirs — each dir keeps its own content after sync"
# app-a: teamscope/default
has_stage3 "$A" "services/environment/teamscope/default/kustomization.yaml"  "MARKER=teamscope-default-v2"  "app-a: teamscope/default v2 in stage 3 right panel"
has        "$A/services/environment/teamscope/default/kustomization.yaml"  "ENV=teamscope"                "app-a: teamscope/default has teamscope ENV"
has_not    "$A/services/environment/teamscope/default/kustomization.yaml"  "MARKER=vs-ont-default"        "app-a: teamscope/default has no vs-ont content"
has_not    "$A/services/environment/teamscope/default/kustomization.yaml"  "MARKER=vs-tst-default"        "app-a: teamscope/default has no vs-tst content"
# app-a: vs-ont/default
has_stage3 "$A" "services/environment/vs-ont/default/kustomization.yaml"     "MARKER=vs-ont-default-v2"     "app-a: vs-ont/default v2 in stage 3 right panel"
has        "$A/services/environment/vs-ont/default/kustomization.yaml"     "ENV=vs-ont"                   "app-a: vs-ont/default has vs-ont ENV"
has_not    "$A/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=teamscope-default"     "app-a: vs-ont/default has no teamscope content"
has_not    "$A/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=vs-tst-default"        "app-a: vs-ont/default has no vs-tst content"
# app-a: vs-tst/default
has_stage3 "$A" "services/environment/vs-tst/default/kustomization.yaml"     "MARKER=vs-tst-default-v2"     "app-a: vs-tst/default v2 in stage 3 right panel"
has        "$A/services/environment/vs-tst/default/kustomization.yaml"     "ENV=vs-tst"                   "app-a: vs-tst/default has vs-tst ENV"
has_not    "$A/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=teamscope-default"     "app-a: vs-tst/default has no teamscope content"
has_not    "$A/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=vs-ont-default"        "app-a: vs-tst/default has no vs-ont content"
# app-b: same checks
has_stage3 "$B" "services/environment/teamscope/default/kustomization.yaml"  "MARKER=teamscope-default-v2"  "app-b: teamscope/default v2 in stage 3 right panel"
has_not    "$B/services/environment/teamscope/default/kustomization.yaml"  "MARKER=vs-ont-default"        "app-b: teamscope/default has no vs-ont content"
has_not    "$B/services/environment/teamscope/default/kustomization.yaml"  "MARKER=vs-tst-default"        "app-b: teamscope/default has no vs-tst content"
has_stage3 "$B" "services/environment/vs-ont/default/kustomization.yaml"     "MARKER=vs-ont-default-v2"     "app-b: vs-ont/default v2 in stage 3 right panel"
has_not    "$B/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=teamscope-default"     "app-b: vs-ont/default has no teamscope content"
has_stage3 "$B" "services/environment/vs-tst/default/kustomization.yaml"     "MARKER=vs-tst-default-v2"     "app-b: vs-tst/default v2 in stage 3 right panel"
has_not    "$B/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=teamscope-default"     "app-b: vs-tst/default has no teamscope content"

# ── app-c: brand-new target dirs — substitutions applied on first copy ────────
# app-c starts with ONLY teamscope/default.  vs-ont/default and vs-tst/default
# are absent from the target.  After sync they must be created with:
#   a) correct env-specific content (not teamscope content)
#   b) substitutions applied (source-app → app-c)
section "app-c  new target dirs — content correct and substitutions applied"
exists  "$C/services/environment/teamscope/default/kustomization.yaml"  "app-c: teamscope/default exists"
has_stage3 "$C" "services/environment/teamscope/default/kustomization.yaml"  "MARKER=teamscope-default-v2"  "app-c: teamscope/default v2 in stage 3 right panel"
has     "$C/services/environment/teamscope/default/kustomization.yaml"  "app-c-teamscope-default"          "app-c: teamscope/default substitution applied"
has_not "$C/services/environment/teamscope/default/kustomization.yaml"  "source-app"                       "app-c: no source-app in teamscope/default"
# vs-ont/default: brand new — created from source, substitution applied
exists  "$C/services/environment/vs-ont/default/kustomization.yaml"     "app-c: vs-ont/default created"
has     "$C/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=vs-ont-default-v2"         "app-c: vs-ont/default has correct v2 content"
has     "$C/services/environment/vs-ont/default/kustomization.yaml"     "ENV=vs-ont"                       "app-c: vs-ont/default has vs-ont ENV"
has     "$C/services/environment/vs-ont/default/kustomization.yaml"     "app-c-vs-ont-default"             "app-c: vs-ont/default substitution applied"
has_not "$C/services/environment/vs-ont/default/kustomization.yaml"     "source-app"                       "app-c: no source-app in vs-ont/default"
has_not "$C/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=teamscope-default"         "app-c: vs-ont/default has no teamscope content"
has_not "$C/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=vs-tst-default"            "app-c: vs-ont/default has no vs-tst content"
# vs-tst/default: brand new — same checks
exists  "$C/services/environment/vs-tst/default/kustomization.yaml"     "app-c: vs-tst/default created"
has     "$C/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=vs-tst-default-v2"         "app-c: vs-tst/default has correct v2 content"
has     "$C/services/environment/vs-tst/default/kustomization.yaml"     "ENV=vs-tst"                       "app-c: vs-tst/default has vs-tst ENV"
has     "$C/services/environment/vs-tst/default/kustomization.yaml"     "app-c-vs-tst-default"             "app-c: vs-tst/default substitution applied"
has_not "$C/services/environment/vs-tst/default/kustomization.yaml"     "source-app"                       "app-c: no source-app in vs-tst/default"
has_not "$C/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=teamscope-default"         "app-c: vs-tst/default has no teamscope content"
has_not "$C/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=vs-ont-default"            "app-c: vs-tst/default has no vs-ont content"

# ── Addition 1: app-f silently skipped during deploy sync ────────────────────
# app-f has only an "app" section (no "deploy") — must not be cloned or cause
# any failure during a deploy-type sync run.
section "app-f silently skipped during deploy sync (no deploy section)"
if [[ ! -d "$WORK_DIR/app-f" ]]; then
  ok "app-f not cloned during deploy sync"
else
  fail "app-f should not have been cloned during deploy sync (no deploy section)"
fi

# ── Addition 2: app-g auto-derived path substitution ─────────────────────────
# app-g has no explicit path_substitutions — the script must auto-derive
# source-app → app-g from the app_name content substitution.
G="$WORK_DIR/app-g"

section "app-g  auto-derived path sub — added file renamed correctly"
absent  "$G/overlays/dev/source-app-internal-svc.yaml"  "source-app filename not present in app-g"
exists  "$G/overlays/dev/app-g-internal-svc.yaml"        "auto-derived path sub: app-g filename exists"
has     "$G/overlays/dev/app-g-internal-svc.yaml"  "name: app-g-internal"  "content substituted in auto-derived file"
has     "$G/overlays/dev/app-g-internal-svc.yaml"  "namespace: ns-g"       "namespace substituted in auto-derived file"
has_not "$G/overlays/dev/app-g-internal-svc.yaml"  "source-app"            "source-app not in auto-derived file"

section "app-g  auto-derived path sub — content and protected key"
has_stage3 "$G" "base/configmap.yaml"  "APP_SETTING: updated-value"  "non-protected key in stage 3 right panel (app-g)"
has     "$G/base/configmap.yaml"  "DATABASE_URL: app-g-postgres.ns-g.svc.cluster.local" "protected DATABASE_URL preserved in app-g"
has_not "$G/base/configmap.yaml"  "DATABASE_URL: changed-db.internal"                   "source DATABASE_URL not in app-g"
has_not "$G/base/configmap.yaml"  "source-app"                                           "source-app not in app-g configmap"

section "app-g  auto-derived path sub — deletion and image preservation"
absent  "$G/base/old-feature.yaml"  "old-feature.yaml deleted from app-g"
has     "$G/base/deployment.yaml"   "image: image-g:app-g-v1.0.0"  "image tag preserved in app-g"
has_not "$G/base/deployment.yaml"   "source-image"                  "source-image not in app-g deployment"
has_stage3 "$G" "base/deployment.yaml"  "NEW_FEATURE"  "new env var in stage 3 right panel (app-g)"

# ─────────────────────────────────────────────────────────────────────────────
# SCENARIO: app-e copy mode
# Run a second sync invocation with --mode copy
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (copy mode: source → app-e, v1.0.0 → v1.1.0)${NC}"

bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source \
  --type    deploy \
  --mode    copy \
  --targets app-e \
  --from    v1.0.0 \
  --to      v1.1.0

E="$WORK_DIR/app-e"

section "app-e  copy mode — files present"
exists  "$E/base/configmap.yaml"    "base/configmap.yaml exists (from source)"
exists  "$E/base/deployment.yaml"   "base/deployment.yaml exists (from source)"
exists  "$E/base/service.yaml"      "base/service.yaml exists (from source, not in diff but in tree)"

section "app-e  copy mode — extra-target-only.yaml deleted"
absent  "$E/base/extra-target-only.yaml"  "base/extra-target-only.yaml absent (not in source)"

section "app-e  copy mode — old-feature.yaml absent"
absent  "$E/base/old-feature.yaml"  "base/old-feature.yaml absent (not in source at v1.1.0)"

section "app-e  copy mode — no conflict markers"
has_not "$E/base/configmap.yaml"    "<<<<<<<"  "no conflict markers in configmap"
has_not "$E/base/deployment.yaml"   "<<<<<<<"  "no conflict markers in deployment"

section "app-e  copy mode — substitutions applied"
has     "$E/base/configmap.yaml"    "app-e"              "app-e name in configmap"
has_not "$E/base/configmap.yaml"    "source-app"         "source-app not in configmap"
has     "$E/base/configmap.yaml"    "SERVICE_NAME: app-e-service"  "service name substituted"

section "app-e  copy mode — image tag preserved from target"
has     "$E/base/deployment.yaml"   "image-e:app-e-LOCAL-TAG-2.5.0"  "local image tag preserved in copy mode"
has_not "$E/base/deployment.yaml"   "image-e:v1.0.0"                 "source image tag not used"
has_not "$E/base/deployment.yaml"   "source-image"                   "source image name not present"

section "app-e  copy mode — branch name correct"
_branch_e=$(git -C "$E" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$_branch_e" == "sync/deploy-copy-from-v1.0.0-to-v1.1.0" ]]; then
  ok "branch is sync/deploy-copy-from-v1.0.0-to-v1.1.0"
else
  fail "expected sync/deploy-copy-from-v1.0.0-to-v1.1.0, got $_branch_e"
fi
unset _branch_e

# ─────────────────────────────────────────────────────────────────────────────
# SCENARIO: app-f Maven app repo, diff mode
# Run a third sync invocation with --type app
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (app type diff mode: source → app-f, v1.0.0 → v1.1.0)${NC}"

bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source \
  --type    app \
  --targets app-f \
  --from    v1.0.0 \
  --to      v1.1.0

F="$WORK_DIR/app-f"

section "app-f  app repo diff — Service.java updated"
exists  "$F/app-f-core/src/main/java/com/app/f/Service.java"  "Service.java exists at app-f path"
has_stage3 "$F" "app-f-core/src/main/java/com/app/f/Service.java"  "version()"  "version() method in stage 3 right panel"
has     "$F/app-f-core/src/main/java/com/app/f/Service.java"  "localExtra()"      "localExtra() preserved from target"
has     "$F/app-f-core/src/main/java/com/app/f/Service.java"  "com.app.f"         "package substituted to com.app.f"
has_not "$F/app-f-core/src/main/java/com/app/f/Service.java"  "com.source.app"    "source package not present"

section "app-f  app repo diff — NewHelper.java added with path substitution"
exists  "$F/app-f-core/src/main/java/com/app/f/NewHelper.java"    "NewHelper.java at app-f path"
has     "$F/app-f-core/src/main/java/com/app/f/NewHelper.java"    "com.app.f"       "package substituted in NewHelper"
has_not "$F/app-f-core/src/main/java/com/app/f/NewHelper.java"    "com.source.app"  "source package not in NewHelper"
absent  "$F/source-app-core/src/main/java/com/source/app/NewHelper.java"  "NewHelper not at source path"

section "app-f  app repo diff — OldUtil.java deleted"
absent  "$F/app-f-core/src/main/java/com/app/f/OldUtil.java"  "OldUtil.java deleted"

section "app-f  app repo diff — pom.xml updated"
has_stage3 "$F" "pom.xml"  "Updated description"  "description in stage 3 right panel"
has     "$F/pom.xml"  "app-f"                 "app-f in pom.xml"
has_not "$F/pom.xml"  "source-app"            "source-app not in pom.xml"

section "app-f  app repo diff — source-app-core path absent"
# The path substitution maps source-app-core → app-f-core
# So source-app-core/ directory should not exist in app-f
if [[ -d "$F/source-app-core" ]]; then
  fail "source-app-core/ directory should not exist in app-f (path not substituted)"
else
  ok "source-app-core/ absent from app-f clone (paths correctly substituted)"
fi

section "app-f  app repo diff — branch name correct"
_branch_f=$(git -C "$F" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$_branch_f" == "sync/app-diff-from-v1.0.0-to-v1.1.0" ]]; then
  ok "branch is sync/app-diff-from-v1.0.0-to-v1.1.0"
else
  fail "expected sync/app-diff-from-v1.0.0-to-v1.1.0, got $_branch_f"
fi
unset _branch_f

# ─────────────────────────────────────────────────────────────────────────────
# 4th sync: app-h — global key-search and container discrimination
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (app type diff mode: source-kv → app-h, v1.0.0 → v1.1.0)${NC}"

bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source-kv \
  --type    app \
  --targets app-h \
  --from    v1.0.0 \
  --to      v1.1.0 || true   # conflict in pom.xml → exit 1 expected

H="$WORK_DIR/app-h"

# ── properties file: version diff in stages, working tree clean ───────────────
# app.version differs: target has 2.5.0, source_B has 1.1.0.
# Working tree stays as clean target; stage 3 has 1.1.0 (shown green in IntelliJ).
section "app-h  properties — version diff in stages, working tree clean"
has_not "$H/app.properties"  "app.version=1.1.0"  "source version not in working tree (in stage 3 right panel)"
has     "$H/app.properties"  "app.name=app-h"     "unchanged line preserved in working tree"
has     "$H/app.properties"  "app.version=2.5.0"  "target version in clean working tree"
has_not "$H/app.properties"  "<<<<<<<"             "working tree clean — conflict in git stages"

# ── container discrimination: pom.xml ────────────────────────────────────────
# Source diff changes <version> inside <parent>.  Target has no <parent> block.
# Global search finds two <version> elements but both fail in_xml_container
# ("parent" not found as ancestor) → try_apply_global returns 0 → conflict
# markers written.  The existing project <version>3.0.0</version> must NOT be
# overwritten; the dependency <version>5.0.0</version> must also be untouched.
section "app-h  container discrimination — project version preserved"
has     "$H/pom.xml"  "<version>3.0.0</version>"  "project version 3.0.0 not overwritten by wrong-container match"
has     "$H/pom.xml"  "<version>5.0.0</version>"  "dependency version 5.0.0 untouched"
has_not "$H/pom.xml"  "<<<<<<<"                   "working tree clean — conflict in git stages"

# ── stage setup: correct LEFT / RIGHT panels for IntelliJ merge dialog ────────
# Stage 1 = target (BASE): IntelliJ diffs both sides against target, so only
#           source v1→v2 changes are highlighted — no noise from customisations.
# Stage 2 = target (LEFT): clean starting point with no highlights.
# Stage 3 = patched target (RIGHT): target + source v1→v2 changes; only those
#           lines differ from stage 1, so only they are highlighted green.
section "app-h  stage setup — stage 1/2/3 = target / target / source_B"
_stage1=$(git -C "$H" cat-file blob :1:pom.xml 2>/dev/null || true)
_stage2=$(git -C "$H" cat-file blob :2:pom.xml 2>/dev/null || true)
_stage3=$(git -C "$H" cat-file blob :3:pom.xml 2>/dev/null || true)
if [[ -z "$_stage1" || -z "$_stage2" || -z "$_stage3" ]]; then
  fail "one or more stages missing for pom.xml"
else
  ok "all three stages registered for pom.xml"
  # Stage 1 = target (BASE): NO <parent> block, has project version 3.0.0
  if echo "$_stage1" | grep -qF "<parent>"; then
    fail "stage 1 should be target (no <parent> block)"
  else
    ok "stage 1 (base) is target — no <parent> block from source"
  fi
  if echo "$_stage1" | grep -qF "3.0.0"; then
    ok "stage 1 (base) has target-only project version 3.0.0"
  else
    fail "stage 1 should be target (contain project version 3.0.0)"
  fi
  # Stage 2 = target: same as stage 1
  if echo "$_stage2" | grep -qF "<parent>"; then
    fail "stage 2 should be original target (has no <parent> block)"
  else
    ok "stage 2 (ours) is original target — no <parent> block from source"
  fi
  if echo "$_stage2" | grep -qF "3.0.0"; then
    ok "stage 2 preserves target-only project version 3.0.0"
  else
    fail "stage 2 should preserve target project version 3.0.0"
  fi
  # Stage 3 = source_B (tag2 end state): has <parent> block with updated 1.1.0
  # highlighted green (differs from stage1=target which has no <parent>).
  # 3.0.0 is target-only XML with no extractable key — correctly absent from
  # stage3; IntelliJ shows it as "deleted by right" so user can keep it.
  if echo "$_stage3" | grep -qF "1.1.0"; then
    ok "stage 3 (right panel) contains updated version 1.1.0 (highlighted green)"
  else
    fail "stage 3 should contain updated version 1.1.0"
  fi
  if echo "$_stage3" | grep -qF "<parent>"; then
    ok "stage 3 is source_B — has <parent> block (source end-tag structure)"
  else
    fail "stage 3 should be source_B and contain <parent> block"
  fi
fi
unset _stage1 _stage2 _stage3

# ─────────────────────────────────────────────────────────────────────────────
# 5th sync: app-l — try_inject_by_key and deletion auto-apply
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (app type diff mode: source-inj → app-l, v1.0.0 → v1.1.0)${NC}"

bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source-inj \
  --type    app \
  --targets app-l \
  --from    v1.0.0 \
  --to      v1.1.0 || true   # conflict in app.xml → exit 1 expected

L="$WORK_DIR/app-l"

# ── conflict markers at every diff location ──────────────────────────────────
# Every diff between target and source_B gets a conflict marker.
# Target value (<mode>enterprise</mode>) is in ours section.
# Source value (<mode>advanced</mode> + <plugin>) is in theirs section.
section "app-l  diff in stages, working tree clean"
has_not "$L/app.xml"  "<<<<<<<"                  "working tree clean — conflict in git stages"
has     "$L/app.xml"  "<mode>enterprise</mode>"  "target value in clean working tree"
_stg1_app=$(git -C "$L" cat-file blob :1:app.xml 2>/dev/null || true)
_stg2_app=$(git -C "$L" cat-file blob :2:app.xml 2>/dev/null || true)
_stg3_app=$(git -C "$L" cat-file blob :3:app.xml 2>/dev/null || true)
if [[ -z "$_stg1_app" || -z "$_stg2_app" || -z "$_stg3_app" ]]; then
  fail "one or more stages missing for app.xml"
else
  ok "all three stages registered for app.xml"
  if echo "$_stg2_app" | grep -qF "<mode>enterprise</mode>"; then
    ok "stage 2 (ours) preserves original target value <mode>enterprise</mode>"
  else
    fail "stage 2 should preserve original target <mode>enterprise</mode>"
  fi
  if echo "$_stg3_app" | grep -qF "<mode>advanced</mode>"; then
    ok "stage 3 (theirs) contains desired new value <mode>advanced</mode>"
  else
    fail "stage 3 should contain source_B value <mode>advanced</mode>"
  fi
  if echo "$_stg3_app" | grep -qF "<plugin>enabled</plugin>"; then
    ok "stage 3 (theirs) contains new add-only line <plugin>enabled</plugin>"
  else
    fail "stage 3 should contain new line <plugin>enabled</plugin>"
  fi
fi
unset _stg1_app _stg2_app _stg3_app

# ── deletion shown as conflict ────────────────────────────────────────────────
# Source deleted <item>remove-this</item>; target still has it.
# Conflict marker wraps the deletion: target line in ours, empty in theirs.
section "app-l  deletion — <item> in stage 2 (right panel shows deletion green)"
has     "$L/legacy.xml"  "<item>remove-this</item>"  "<item> in working tree (stage 3 right panel shows deletion — click >>)"
has     "$L/legacy.xml"  "<section-diff>"             "surrounding target content preserved"

# ─────────────────────────────────────────────────────────────────────────────
# 6th sync: app-k — duplicate-key occurrence-order matching (K8s deployment)
#   deployment.yaml has multiple - name:/value: pairs.  Only APP_SETTING
#   changed v1→v2.  Stage 3 must use target values for all unchanged env vars
#   (not the last-occurrence substitution that caused wrong values) and keep
#   EXTRA_CONFIG (target-only env var) in place.
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (dup-key K8s: source-dup → app-k, v1.0.0 → v1.1.0)${NC}"

bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source-dup \
  --type    app \
  --targets app-k \
  --from    v1.0.0 \
  --to      v1.1.0 || true

K="$WORK_DIR/app-k"

section "app-k  duplicate-key — working tree is clean target"
has_not "$K/deployment.yaml" "<<<<<<" "no conflict markers in working tree"
has     "$K/deployment.yaml" "replicas: 3"         "target replicas preserved in working tree"
has     "$K/deployment.yaml" "value: prod-db"       "target DATABASE_URL value in working tree"
has     "$K/deployment.yaml" "value: custom-value"  "target APP_SETTING value in working tree"
has     "$K/deployment.yaml" "value: warn"          "target LOG_LEVEL value in working tree"
has     "$K/deployment.yaml" "value: target-only"   "target-only EXTRA_CONFIG in working tree"

section "app-k  duplicate-key — stage 3 correct occurrence-order substitution"
_s3=$(git -C "$K" cat-file blob :3:deployment.yaml 2>/dev/null || true)
if [[ -z "$_s3" ]]; then
  fail "stage 3 missing for deployment.yaml"
else
  ok "stage 3 registered for deployment.yaml"

  # Unchanged env vars must use TARGET values (not source values)
  if echo "$_s3" | grep -qF "value: prod-db"; then
    ok "stage 3: DATABASE_URL uses target value prod-db (not source localhost)"
  else
    fail "stage 3: DATABASE_URL should be prod-db (target value, not highlighted)"
  fi
  if echo "$_s3" | grep -qF "value: warn"; then
    ok "stage 3: LOG_LEVEL uses target value warn (not source debug)"
  else
    fail "stage 3: LOG_LEVEL should be warn (target value, not highlighted)"
  fi

  # The changed env var must show source_B value (highlighted)
  if echo "$_s3" | grep -qF "value: updated-value"; then
    ok "stage 3: APP_SETTING shows updated-value (v1→v2 change, highlighted green)"
  else
    fail "stage 3: APP_SETTING should be updated-value (v1→v2 change)"
  fi
  if echo "$_s3" | grep -qF "value: custom-value"; then
    fail "stage 3: APP_SETTING must NOT show custom-value (that is stage 1, not stage 3)"
  else
    ok "stage 3: APP_SETTING does not retain custom-value from target"
  fi

  # Source v1 value must NOT appear (would mean substitution used wrong occurrence)
  if echo "$_s3" | grep -qF "value: original-value"; then
    fail "stage 3 must not contain source v1 value original-value"
  else
    ok "stage 3 does not contain stale source v1 value original-value"
  fi
  if echo "$_s3" | grep -qF "value: localhost"; then
    fail "stage 3 must not contain source v1 DATABASE_URL value localhost"
  else
    ok "stage 3 does not contain stale source value localhost"
  fi

  # Pure addition in v2 must be present (highlighted)
  if echo "$_s3" | grep -qF "value: enabled"; then
    ok "stage 3: NEW_FEATURE (v1→v2 addition) is present and highlighted"
  else
    fail "stage 3 should contain NEW_FEATURE: enabled (v1→v2 addition)"
  fi

  # Target-only env var must be preserved (not highlighted, same as stage 1)
  if echo "$_s3" | grep -qF "value: target-only"; then
    ok "stage 3: target-only EXTRA_CONFIG preserved (not highlighted)"
  else
    fail "stage 3 should contain EXTRA_CONFIG: target-only (target-only env var)"
  fi

  # replicas: target's value must be in stage 3 (not source's 1)
  if echo "$_s3" | grep -qF "replicas: 3"; then
    ok "stage 3: replicas uses target value 3 (not source value 1)"
  else
    fail "stage 3: replicas should be 3 (target value)"
  fi
fi
unset _s3

# ─────────────────────────────────────────────────────────────────────────────
# 7th sync: app-m — duplicate-key occurrence-order matching (Maven pom.xml)
#   pom.xml has multiple <version>, <groupId>, <artifactId>, <dependency>
#   blocks.  v1→v2: parent bumped 2.0.0→2.1.0, lib-b bumped 1.0.0→1.5.0,
#   lib-c added.  Target: no parent, own lib-a version, own lib-d.
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (dup-key Maven: source-dup → app-m, v1.0.0 → v1.1.0)${NC}"

bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source-dup \
  --type    app \
  --targets app-m \
  --from    v1.0.0 \
  --to      v1.1.0 || true

M="$WORK_DIR/app-m"

section "app-m  Maven pom.xml — working tree is clean target"
has_not "$M/pom.xml" "<<<<<<" "no conflict markers in working tree"
has     "$M/pom.xml" "4.0.0"   "target project version 4.0.0 in working tree"
has     "$M/pom.xml" "5.0.0"   "target lib-a version 5.0.0 in working tree"
has     "$M/pom.xml" "lib-d"   "target-only lib-d in working tree"

section "app-m  Maven pom.xml — stage 3 correct for duplicate XML tags"
_s3=$(git -C "$M" cat-file blob :3:pom.xml 2>/dev/null || true)
if [[ -z "$_s3" ]]; then
  fail "stage 3 missing for pom.xml"
else
  ok "stage 3 registered for pom.xml"

  # v1→v2: parent version bumped — must be highlighted (present with new value)
  if echo "$_s3" | grep -qF "2.1.0"; then
    ok "stage 3: parent version 2.1.0 present (v1→v2 change, highlighted)"
  else
    fail "stage 3 should contain parent version 2.1.0"
  fi
  if echo "$_s3" | grep -qF "2.0.0"; then
    fail "stage 3 must not contain old parent version 2.0.0"
  else
    ok "stage 3 does not contain stale parent version 2.0.0"
  fi

  # v1→v2: lib-b bumped 1.0.0→1.5.0 — must be highlighted
  if echo "$_s3" | grep -qF "1.5.0"; then
    ok "stage 3: lib-b version 1.5.0 present (v1→v2 change, highlighted)"
  else
    fail "stage 3 should contain lib-b version 1.5.0"
  fi

  # v1→v2: lib-c added — must be present (highlighted)
  if echo "$_s3" | grep -qF "lib-c"; then
    ok "stage 3: lib-c present (v1→v2 addition, highlighted)"
  else
    fail "stage 3 should contain lib-c (v1→v2 addition)"
  fi

  # lib-a: in source v1 and v2 (unchanged), target has own version 5.0.0
  # stage 3 should keep lib-a but with either target (5.0.0) or source (3.0.0) version.
  # Most important: 3.0.0 (source value) must NOT replace target's 5.0.0 silently.
  if echo "$_s3" | grep -qF "lib-a"; then
    ok "stage 3: lib-a present"
  else
    fail "stage 3 should contain lib-a"
  fi

  # lib-d: target-only XML dependency — XML keyless tags cannot be reliably
  # detected as target-only by the key-based algorithm (linekey returns ""
  # for <tag>value</tag> elements), so lib-d will appear absent from stage 3
  # (shown as "deleted from right panel" in IntelliJ).  The working tree
  # check above already confirms lib-d is preserved.
  if echo "$_s3" | grep -qF "lib-d"; then
    ok "stage 3: target-only lib-d present in stage 3"
  else
    ok "stage 3: lib-d absent from stage 3 (XML target-only; preserved in working tree)"
  fi
fi
unset _s3

# ─────────────────────────────────────────────────────────────────────────────
# 8th sync: app-del — deleted source key must NOT appear in stage3
#   source v1.0.0→v1.1.0: KEY_A value changed, KEY_B deleted, KEY_C added.
#   Target still has KEY_B and a target-only KEY_D.
#   Stage3 must NOT contain KEY_B (it was deleted from source v2).
#   Stage3 MUST contain KEY_C (new addition) and KEY_D (target-only).
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (deletion test: source-del → app-del, v1.0.0 → v1.1.0)${NC}"

bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source-del \
  --type    app \
  --targets app-del \
  --from    v1.0.0 \
  --to      v1.1.0 || true

DEL="$WORK_DIR/app-del"

section "app-del  deletion — working tree is clean target"
has_not "$DEL/config.yaml" "<<<<<<" "no conflict markers in working tree"
has     "$DEL/config.yaml" "value: prod-a"       "target KEY_A value in working tree"
has     "$DEL/config.yaml" "value: prod-b"       "target KEY_B value in working tree"
has     "$DEL/config.yaml" "value: target-only"  "target-only KEY_D in working tree"

section "app-del  deletion — stage3 correct (deleted key absent, target-only preserved)"
_s3del=$(git -C "$DEL" cat-file blob :3:config.yaml 2>/dev/null || true)
if [[ -z "$_s3del" ]]; then
  fail "stage 3 missing for config.yaml"
else
  ok "stage 3 registered for config.yaml"

  # KEY_B was in source v1 and target, but DELETED from source v2
  # → must NOT appear in stage3 (right panel = source v2 end state)
  if echo "$_s3del" | grep -qF "KEY_B"; then
    fail "stage 3 must NOT contain KEY_B (deleted from source v2)"
  else
    ok "stage 3 does not contain KEY_B (correctly absent — deleted in source v2)"
  fi
  if echo "$_s3del" | grep -qF "prod-b"; then
    fail "stage 3 must NOT contain prod-b (KEY_B value, deleted in source v2)"
  else
    ok "stage 3 does not contain KEY_B value prod-b"
  fi

  # KEY_A value changed v1→v2 (val-a → val-a-new) → must be highlighted
  if echo "$_s3del" | grep -qF "val-a-new"; then
    ok "stage 3: KEY_A shows val-a-new (v1→v2 change, highlighted)"
  else
    fail "stage 3 should contain KEY_A new value val-a-new"
  fi

  # KEY_C was added in source v2 → must appear (highlighted)
  if echo "$_s3del" | grep -qF "KEY_C"; then
    ok "stage 3: KEY_C present (v1→v2 addition, highlighted)"
  else
    fail "stage 3 should contain KEY_C (added in source v2)"
  fi

  # KEY_D is target-only → must be re-inserted in stage3
  if echo "$_s3del" | grep -qF "KEY_D"; then
    ok "stage 3: target-only KEY_D preserved (re-inserted, not highlighted)"
  else
    fail "stage 3 should contain KEY_D (target-only, must be re-inserted)"
  fi
fi
unset _s3del

# ─────────────────────────────────────────────────────────────────────────────
# 9th sync: app-prekey — pre-key comment must survive in stage3
#   Regression for theirs_last_p uninitialised bug: comments before the first
#   keyed line were stored under anchor ("",0) but looked up under ("",""),
#   causing them to be silently dropped from stage3.
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (pre-key comment test: source-prekey → app-prekey, v1.0.0 → v1.1.0)${NC}"

bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source-prekey \
  --type    app \
  --targets app-prekey \
  --from    v1.0.0 \
  --to      v1.1.0 || true

PK="$WORK_DIR/app-prekey"

section "app-prekey  pre-key comment — stage3 contains leading comment"
_s3pk=$(git -C "$PK" cat-file blob :3:versions.xml 2>/dev/null || true)
if [[ -z "$_s3pk" ]]; then
  fail "stage 3 missing for versions.xml"
else
  ok "stage 3 registered for versions.xml"

  if echo "$_s3pk" | grep -qF "<!-- managed versions -->"; then
    ok "stage 3 contains pre-key comment (not dropped by anchor mismatch)"
  else
    fail "stage 3 must contain '<!-- managed versions -->' (pre-key comment)"
  fi

  if echo "$_s3pk" | grep -qF "<version.a>1.0.0</version.a>"; then
    ok "stage 3: version.a unchanged — correctly not highlighted"
  else
    fail "stage 3 should contain version.a 1.0.0 (unchanged)"
  fi

  if echo "$_s3pk" | grep -qF "<version.b>2.1.0</version.b>"; then
    ok "stage 3: version.b shows 2.1.0 (v1→v2 change, highlighted)"
  else
    fail "stage 3 should show version.b 2.1.0 (changed in source v2)"
  fi
fi
unset _s3pk

# ─────────────────────────────────────────────────────────────────────────────
# 10th sync: app-jenkins — Jenkinsfile with Groovy/URL lines must not be
#            misidentified as YAML keys (regression for linekey() false-positive)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (Jenkinsfile test: source-jenkins → app-jenkins, v1.0.0 → v1.1.0)${NC}"

bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source-jenkins \
  --type    app \
  --targets app-jenkins \
  --from    v1.0.0 \
  --to      v1.1.0 || true

JK="$WORK_DIR/app-jenkins"

section "app-jenkins  Jenkinsfile — stage3 preserves structural lines unchanged"
_s3jk=$(git -C "$JK" cat-file blob :3:Jenkinsfile 2>/dev/null || true)
if [[ -z "$_s3jk" ]]; then
  fail "stage 3 missing for Jenkinsfile"
else
  ok "stage 3 registered for Jenkinsfile"

  # Header comment must survive (was dropped when choice() set tgt_had_keys=1)
  if echo "$_s3jk" | grep -qF "/*************"; then
    ok "stage 3 preserves block-comment header (not dropped by false-key mismatch)"
  else
    fail "stage 3 must contain block-comment header '/**'"
  fi

  # choice() line unchanged in v1→v2 — must appear unmodified in stage3
  if echo "$_s3jk" | grep -qF "choice(choices:"; then
    ok "stage 3 preserves choice() line (Groovy ':' not treated as YAML key)"
  else
    fail "stage 3 must contain choice() line unchanged"
  fi

  # URL comment unchanged — must appear (was false-keyed by '://' before fix)
  if echo "$_s3jk" | grep -qF "https://crontab.guru"; then
    ok "stage 3 preserves URL comment (URL ':' not treated as YAML key)"
  else
    fail "stage 3 must contain URL comment unchanged"
  fi

  # Changed cron lines must be present (highlighted = source v2 values)
  if echo "$_s3jk" | grep -qF "New comment:"; then
    ok "stage 3 shows changed cron comment (highlighted)"
  else
    fail "stage 3 must show changed cron comment 'New comment:'"
  fi

  # Old cron comment must NOT be in stage3
  if echo "$_s3jk" | grep -qF "Old comment:"; then
    fail "stage 3 must NOT contain old cron comment (replaced in source v2)"
  else
    ok "stage 3 does not contain old cron comment (correctly replaced)"
  fi
fi
unset _s3jk

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
