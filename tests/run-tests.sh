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
# Also redirect the SSH form so a run with no BITBUCKET_USER/TOKEN (which makes
# _bb_url fall back to git@bitbucket.org:...) still resolves to the local bares.
git config --global \
  --add "url.file://${REMOTES}/.insteadOf" \
  "git@bitbucket.org:testspace/"

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
# Generate test repos.json pointing to our local testspace/ repos
# Uses the new grouped "apps" structure
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# SOURCE MC REPO  (testspace/source-mc-app)  [multi-conflict regression]
# v1.0.0 → deployment.yaml with replicas/LOG_LEVEL/TIMEOUT
# v1.1.0 → all three values changed → applied onto a target that customised the
#          same three values produces >= 2 conflict hunks (git merge-file rc>=2).
# Regression for: rc>1 from git merge-file being misread as a hard error, which
# committed raw <<<<<<< markers instead of registering index stages 1/2/3.
# ─────────────────────────────────────────────────────────────────────────────
make_bare "source-mc-app"

source_mc_v1() {
  cat > deployment.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: source-app
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
  template:
    spec:
      containers:
        - name: main
          env:
            - name: LOG_LEVEL
              value: info
            - name: REGION
              value: eu-west
            - name: TIMEOUT
              value: "30"
YAML
}
with_work "source-mc-app" "v1.0.0" source_mc_v1

source_mc_v2() {
  cat > deployment.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: source-app
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
  template:
    spec:
      containers:
        - name: main
          env:
            - name: LOG_LEVEL
              value: debug
            - name: REGION
              value: eu-west
            - name: TIMEOUT
              value: "60"
YAML
}
with_work "source-mc-app" "v1.1.0" source_mc_v2

# TARGET MC REPO: app-mc — customised replicas/LOG_LEVEL/TIMEOUT (all differ
# from both source v1 and v2) so the three-way merge conflicts in >= 2 places.
make_bare "app-mc-app"
app_mc_initial() {
  cat > deployment.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-mc
spec:
  replicas: 5
  strategy:
    type: RollingUpdate
  template:
    spec:
      containers:
        - name: main
          env:
            - name: LOG_LEVEL
              value: warn
            - name: REGION
              value: eu-west
            - name: TIMEOUT
              value: "99"
YAML
}
with_work "app-mc-app" "" app_mc_initial

# NOTE: app-fail-app is intentionally NOT created (no make_bare) so cloning it
# fails — used to verify a failed target reports "Failed" and exits 1 WITHOUT
# printing a spurious "[FATAL] aborted" line from the ERR trap.

# TARGET NC REPO: app-nc — content identical to source-mc v1 (after app-nc name
# subs), so the v1->v2 change merges CLEANLY (no conflict).  Used to verify that
# a successful target with NO Bitbucket credentials (empty PR_URL) is still
# reported as PASS — regression for `set -e` treating the final `[[ -n PR_URL ]]`
# test as the subshell's (failing) exit status.
make_bare "app-nc-app"
app_nc_initial() {
  cat > deployment.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-nc
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
  template:
    spec:
      containers:
        - name: main
          env:
            - name: LOG_LEVEL
              value: info
            - name: REGION
              value: eu-west
            - name: TIMEOUT
              value: "30"
YAML
}
with_work "app-nc-app" "" app_nc_initial

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
      "name": "source-mc",
      "app": {
        "repo": "testspace/source-mc-app",
        "substitutions": { "app_name": "source-app" }
      }
    },
    {
      "name": "app-mc",
      "app": {
        "repo": "testspace/app-mc-app",
        "substitutions": { "app_name": "app-mc" }
      }
    },
    {
      "name": "app-fail",
      "app": {
        "repo": "testspace/app-fail-app",
        "substitutions": { "app_name": "app-fail" }
      }
    },
    {
      "name": "app-nc",
      "app": {
        "repo": "testspace/app-nc-app",
        "substitutions": { "app_name": "app-nc" }
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
has     "$A/overlays/dev/kustomization.yaml"  "app-a-configmap-v2.yaml"      "resources reference updated to v2"
has_not "$A/overlays/dev/kustomization.yaml"  "app-a-configmap-v1.yaml"      "old v1 reference removed"
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
has     "$A/services/environment/teamscope/kustomization.yaml"  "MARKER=teamscope-v2"   "teamscope updated in app-a"
has     "$A/services/environment/teamscope/kustomization.yaml"  "app-a-teamscope"        "app-a name substituted in teamscope"
has_not "$A/services/environment/teamscope/kustomization.yaml"  "source-app"             "source name not present in app-a teamscope"
has     "$A/services/environment/enva/kustomization.yaml"       "MARKER=app-a-enva-target"  "app-a enva content preserved (not in diff)"
has_not "$A/services/environment/enva/kustomization.yaml"       "MARKER=teamscope-v2"    "teamscope change not bleed into enva"
has     "$A/services/environment/envb/kustomization.yaml"       "MARKER=envb-v1-app-a"   "app-a envb content preserved (not in diff)"
has_not "$A/services/environment/envb/kustomization.yaml"       "MARKER=teamscope-v2"    "teamscope change not bleed into envb"
exists  "$B/services/environment/teamscope/kustomization.yaml"             "teamscope exists in app-b"
has     "$B/services/environment/teamscope/kustomization.yaml"  "MARKER=teamscope-v2"   "teamscope updated in app-b"
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
has     "$A/services/environment/teamscope/default/kustomization.yaml"  "MARKER=teamscope-default-v2"  "app-a: teamscope/default updated to v2"
has     "$A/services/environment/teamscope/default/kustomization.yaml"  "ENV=teamscope"                "app-a: teamscope/default has teamscope ENV"
has_not "$A/services/environment/teamscope/default/kustomization.yaml"  "MARKER=vs-ont-default"        "app-a: teamscope/default has no vs-ont content"
has_not "$A/services/environment/teamscope/default/kustomization.yaml"  "MARKER=vs-tst-default"        "app-a: teamscope/default has no vs-tst content"
# app-a: vs-ont/default
has     "$A/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=vs-ont-default-v2"     "app-a: vs-ont/default updated to v2"
has     "$A/services/environment/vs-ont/default/kustomization.yaml"     "ENV=vs-ont"                   "app-a: vs-ont/default has vs-ont ENV"
has_not "$A/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=teamscope-default"     "app-a: vs-ont/default has no teamscope content"
has_not "$A/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=vs-tst-default"        "app-a: vs-ont/default has no vs-tst content"
# app-a: vs-tst/default
has     "$A/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=vs-tst-default-v2"     "app-a: vs-tst/default updated to v2"
has     "$A/services/environment/vs-tst/default/kustomization.yaml"     "ENV=vs-tst"                   "app-a: vs-tst/default has vs-tst ENV"
has_not "$A/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=teamscope-default"     "app-a: vs-tst/default has no teamscope content"
has_not "$A/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=vs-ont-default"        "app-a: vs-tst/default has no vs-ont content"
# app-b: same checks
has     "$B/services/environment/teamscope/default/kustomization.yaml"  "MARKER=teamscope-default-v2"  "app-b: teamscope/default updated to v2"
has_not "$B/services/environment/teamscope/default/kustomization.yaml"  "MARKER=vs-ont-default"        "app-b: teamscope/default has no vs-ont content"
has_not "$B/services/environment/teamscope/default/kustomization.yaml"  "MARKER=vs-tst-default"        "app-b: teamscope/default has no vs-tst content"
has     "$B/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=vs-ont-default-v2"     "app-b: vs-ont/default updated to v2"
has_not "$B/services/environment/vs-ont/default/kustomization.yaml"     "MARKER=teamscope-default"     "app-b: vs-ont/default has no teamscope content"
has     "$B/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=vs-tst-default-v2"     "app-b: vs-tst/default updated to v2"
has_not "$B/services/environment/vs-tst/default/kustomization.yaml"     "MARKER=teamscope-default"     "app-b: vs-tst/default has no teamscope content"

# ── app-c: brand-new target dirs — substitutions applied on first copy ────────
# app-c starts with ONLY teamscope/default.  vs-ont/default and vs-tst/default
# are absent from the target.  After sync they must be created with:
#   a) correct env-specific content (not teamscope content)
#   b) substitutions applied (source-app → app-c)
section "app-c  new target dirs — content correct and substitutions applied"
exists  "$C/services/environment/teamscope/default/kustomization.yaml"  "app-c: teamscope/default exists"
has     "$C/services/environment/teamscope/default/kustomization.yaml"  "MARKER=teamscope-default-v2"      "app-c: teamscope/default updated to v2"
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
has     "$G/base/configmap.yaml"  "APP_SETTING: updated-value"                          "non-protected key updated in app-g"
has     "$G/base/configmap.yaml"  "DATABASE_URL: app-g-postgres.ns-g.svc.cluster.local" "protected DATABASE_URL preserved in app-g"
has_not "$G/base/configmap.yaml"  "DATABASE_URL: changed-db.internal"                   "source DATABASE_URL not in app-g"
has_not "$G/base/configmap.yaml"  "source-app"                                           "source-app not in app-g configmap"

section "app-g  auto-derived path sub — deletion and image preservation"
absent  "$G/base/old-feature.yaml"  "old-feature.yaml deleted from app-g"
has     "$G/base/deployment.yaml"   "image: image-g:app-g-v1.0.0"  "image tag preserved in app-g"
has_not "$G/base/deployment.yaml"   "source-image"                  "source-image not in app-g deployment"
has     "$G/base/deployment.yaml"   "NEW_FEATURE"                   "new env var added in app-g"

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
has     "$F/app-f-core/src/main/java/com/app/f/Service.java"  "version()"         "version() method added from source diff"
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
has     "$F/pom.xml"  "Updated description"   "description added from source"
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
# SCENARIO: multi-conflict merge + failed-target summary
#   source-mc → app-mc (>= 2 conflict hunks) and app-fail (clone fails).
#   Regression for two bugs:
#     1. git merge-file rc>=2 (conflict COUNT, not an error) was misread as a
#        hard error → file committed with raw <<<<<<< markers, no index stages.
#     2. a failed target tripped the ERR trap → spurious "[FATAL] aborted" line
#        even though remaining targets pushed fine.
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (multi-conflict: source-mc → app-mc,app-fail, v1.0.0 → v1.1.0)${NC}"

set +e
_mc_out=$(bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source-mc \
  --type    app \
  --targets app-mc,app-fail \
  --from    v1.0.0 \
  --to      v1.1.0 2>&1)
_mc_rc=$?
set -e

MC="$WORK_DIR/app-mc"

section "multi-conflict  app-mc — 2+ conflict hunks handled as conflict, not error"
has "$MC/deployment.yaml" "<<<<<<<" "working tree has conflict markers (non-interactive keeps them)"
# Regression: rc>=2 must NOT be logged as a git merge-file error
if grep -qF "git merge-file error" <<< "$_mc_out"; then
  fail "multi-conflict must not be reported as a git merge-file error"
else
  ok "multi-conflict not misreported as a git merge-file error"
fi

section "multi-conflict  app-mc — conflict committed (non-interactive commit succeeds)"
# Regression for the commit path: previously `git add` could not clear the
# injected index stages 1/2/3, so `git commit` refused ("unmerged files") and
# nothing was committed — silently, because the failure was swallowed.  The
# fix force-removes the stages then re-adds, so the marker file is committed.
_mc_head=$(git -C "$MC" cat-file blob "HEAD:deployment.yaml" 2>/dev/null || true)
if [[ -n "$_mc_head" ]] && grep -qF "<<<<<<<" <<< "$_mc_head"; then
  ok "committed HEAD:deployment.yaml exists and contains conflict markers"
else
  fail "conflict file must be committed with markers (commit must not silently fail)"
fi
grep -qF "replicas: 5" <<< "$_mc_head" && ok "committed file shows target value replicas: 5 (ours side of marker)" \
  || fail "committed file should contain target value replicas: 5"
grep -qF "replicas: 2" <<< "$_mc_head" && ok "committed file shows source v2 value replicas: 2 (theirs side of marker)" \
  || fail "committed file should contain source v2 value replicas: 2"
_mc_subj=$(git -C "$MC" log -1 --pretty=%s 2>/dev/null || true)
grep -qF "chore(sync)" <<< "$_mc_subj" && ok "a sync commit was actually created on the branch" \
  || fail "expected a chore(sync) commit on the sync branch (got: '$_mc_subj')"
unset _mc_head _mc_subj

section "multi-conflict  failed target — reported without spurious [FATAL]"
grep -qF "Failed" <<< "$_mc_out" && ok "summary reports the failed target (app-fail)" \
  || fail "summary should report Failed target app-fail"
if grep -qF "[FATAL] aborted" <<< "$_mc_out"; then
  fail "must NOT print '[FATAL] aborted' when a target fails (ERR trap misfire)"
else
  ok "no spurious '[FATAL] aborted' line on partial failure"
fi
[[ $_mc_rc -eq 1 ]] && ok "exit code 1 (a target failed)" \
  || fail "exit code should be 1 when a target fails (got $_mc_rc)"
unset _mc_out _mc_rc

# ─────────────────────────────────────────────────────────────────────────────
# SCENARIO: successful target with NO Bitbucket credentials (empty PR_URL)
#   Regression: with `set -e` active in the per-target subshell, the final
#   `[[ -n "$PR_URL" ]] && log_info` became the subshell's exit status; an empty
#   PR_URL (no credentials → no PR created) then wrongly marked the target FAILED
#   even though the commit and push both succeeded.
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Running sync-deploy.sh  (no-credentials clean merge: source-mc → app-nc)${NC}"

set +e
_nc_out=$(env -u BITBUCKET_USER -u BITBUCKET_TOKEN bash "$SYNC_SCRIPT" \
  --config  "$T/repos.test.json" \
  --source  source-mc \
  --type    app \
  --targets app-nc \
  --from    v1.0.0 \
  --to      v1.1.0 2>&1)
_nc_rc=$?
set -e

NCDIR="$WORK_DIR/app-nc"

section "no-credentials  app-nc — successful target reported as PASS"
[[ $_nc_rc -eq 0 ]] && ok "exit code 0 (target succeeded without credentials)" \
  || fail "exit code should be 0 (got $_nc_rc); no-PR must not fail a pushed target"
grep -qF "Succeeded" <<< "$_nc_out" && ok "run reports a succeeded target" \
  || fail "run should report app-nc as succeeded"
if grep -qF "FAILED: app-nc" <<< "$_nc_out"; then
  fail "app-nc must NOT be marked FAILED when only the PR step is skipped"
else
  ok "app-nc not wrongly marked FAILED"
fi
# The clean merge must actually be committed (no conflict, source v2 values win)
_nc_head=$(git -C "$NCDIR" cat-file blob "HEAD:deployment.yaml" 2>/dev/null || true)
grep -qF "replicas: 2" <<< "$_nc_head" && ok "clean merge committed source v2 value replicas: 2" \
  || fail "clean-merge result should contain source v2 replicas: 2"
if grep -qF "<<<<<<<" <<< "$_nc_head"; then
  fail "clean merge must not contain conflict markers"
else
  ok "clean merge committed without conflict markers"
fi
unset _nc_out _nc_rc _nc_head

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
