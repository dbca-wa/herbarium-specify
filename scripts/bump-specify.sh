#!/bin/bash
# =============================================================================
# Specify Version Bump Script
#
# Updates the pinned specify7-service image tag across all kustomize files
# in one atomic operation, so the base deployments and overlay version
# annotations never drift out of sync.
#
# Files touched:
#   kustomize/base/specify-deployment.yaml          (main app container)
#   kustomize/base/specify-worker-deployment.yaml   (worker container)
#   kustomize/base/nginx-deployment.yaml            (copy-static-files init)
#   kustomize/overlays/uat/kustomization.yaml       (version annotation)
#   kustomize/overlays/prod/kustomization.yaml      (version annotation)
#
# Usage:
#   ./scripts/bump-specify.sh <tag|latest> [--no-verify] [--yes]
#
# The tag may be written with or without the leading 'v':
#   ./scripts/bump-specify.sh 7.12.1.2
#   ./scripts/bump-specify.sh v7.12.1.2
#
# Or resolve the newest release from GitHub automatically (the resolved
# version number is written to the files, never the word "latest"):
#   ./scripts/bump-specify.sh latest
#
# Options:
#   --no-verify   Skip checking the tag exists on GitHub releases
#   --yes, -y     Skip the confirmation prompt (non-interactive)
#
# This script does NOT commit or deploy. Review the diff, then commit
# and roll out with ./scripts/reset-specify.sh <env>.
# =============================================================================

set -e

# --- Resolve repo root so the script works from anywhere ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE="specifyconsortium/specify7-service"
GITHUB_REPO="specify/specify7"

# Files that carry the image tag directly.
IMAGE_FILES=(
    "kustomize/base/specify-deployment.yaml"
    "kustomize/base/specify-worker-deployment.yaml"
    "kustomize/base/nginx-deployment.yaml"
)
# Files that carry the version annotation.
ANNOTATION_FILES=(
    "kustomize/overlays/uat/kustomization.yaml"
    "kustomize/overlays/prod/kustomization.yaml"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}✓${NC} $1"; }
echo_step()  { echo -e "${BLUE}==>${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
echo_error() { echo -e "${RED}✗${NC} $1"; }

show_usage() {
    echo ""
    echo "Usage: $0 <tag|latest> [--no-verify] [--yes]"
    echo ""
    echo "Updates the $IMAGE tag across all kustomize files."
    echo ""
    echo "The tag may be written with or without a leading 'v':"
    echo "  $0 7.12.1.2"
    echo "  $0 v7.12.1.2"
    echo ""
    echo "Or resolve the newest release from GitHub automatically:"
    echo "  $0 latest"
    echo ""
    echo "Options:"
    echo "  --no-verify   Skip checking the tag exists on GitHub releases"
    echo "                (ignored when the tag is 'latest')"
    echo "  --yes, -y     Skip the confirmation prompt"
    echo ""
    exit "${1:-1}"
}

# Resolve the newest release tag from GitHub. Prints the tag (e.g. v7.12.1.2)
# on stdout, or exits non-zero if it can't be determined.
resolve_latest_tag() {
    local tag=""
    if command -v gh > /dev/null 2>&1; then
        # gh release list sorts newest-first; take the tag of the top row.
        tag="$(gh release list --repo "$GITHUB_REPO" --limit 1 2>/dev/null \
            | awk 'NR==1 {print $(NF-1)}')"
        # Fall back to parsing if column layout surprises us.
        [[ "$tag" =~ ^v[0-9] ]] || tag="$(gh release view --repo "$GITHUB_REPO" --json tagName -q .tagName 2>/dev/null || true)"
    elif command -v curl > /dev/null 2>&1; then
        # /releases/latest honors the "latest" flag set on the repo.
        tag="$(curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    else
        echo_error "Need gh or curl to resolve the latest tag." >&2
        return 1
    fi

    if [[ ! "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo_error "Could not resolve the latest release tag from GitHub." >&2
        return 1
    fi
    echo "$tag"
}

# --- Parse arguments ---
TAG=""
VERIFY=true
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-verify) VERIFY=false; shift ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --help|-h) show_usage 0 ;;
        -*) echo_error "Unknown option: $1"; show_usage ;;
        *)
            if [ -n "$TAG" ]; then
                echo_error "Unexpected extra argument: $1"
                show_usage
            fi
            TAG="$1"; shift ;;
    esac
done

[ -z "$TAG" ] && { echo_error "Version tag required"; show_usage; }

cd "$REPO_ROOT"

# --- Resolve the 'latest' keyword to a concrete tag ---
RESOLVED_FROM_LATEST=false
if [ "$TAG" = "latest" ] || [ "$TAG" = "l" ]; then
    echo_step "Resolving the latest release from GitHub ($GITHUB_REPO)..."
    TAG="$(resolve_latest_tag)" || exit 1
    RESOLVED_FROM_LATEST=true
    echo_info "Latest release is $TAG"
    # Resolution already proved the tag exists; no need to re-verify.
    VERIFY=false
fi

# --- Normalize and validate the tag ---
# Accept with or without leading 'v'; store the canonical 'v'-prefixed form.
TAG="${TAG#v}"
if ! [[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo_error "Invalid tag format: 'v$TAG'"
    echo_error "Expected something like 7.12.1 or 7.12.1.2"
    exit 1
fi
NEW_TAG="v$TAG"

# --- Determine the current tag (from the main deployment) ---
CURRENT_TAG="$(grep -oE "${IMAGE}:v[0-9.]+" "kustomize/base/specify-deployment.yaml" 2>/dev/null | head -n1 | cut -d: -f2 || true)"

echo ""
echo_step "Specify Version Bump"
echo "  Current: ${CURRENT_TAG:-unknown}"
echo "  New:     $NEW_TAG"
echo ""

if [ -n "$CURRENT_TAG" ] && [ "$CURRENT_TAG" = "$NEW_TAG" ]; then
    echo_warn "Already pinned to $NEW_TAG — nothing to do."
    exit 0
fi

# --- Verify the tag exists on GitHub (best effort) ---
if [ "$VERIFY" = true ]; then
    echo_step "Verifying $NEW_TAG exists on GitHub ($GITHUB_REPO)..."
    FOUND=""
    if command -v gh > /dev/null 2>&1; then
        if gh release view "$NEW_TAG" --repo "$GITHUB_REPO" > /dev/null 2>&1; then
            FOUND="yes"
        fi
    elif command -v curl > /dev/null 2>&1; then
        CODE="$(curl -s -o /dev/null -w '%{http_code}' \
            "https://api.github.com/repos/$GITHUB_REPO/releases/tags/$NEW_TAG" 2>/dev/null || echo "000")"
        [ "$CODE" = "200" ] && FOUND="yes"
    else
        echo_warn "Neither gh nor curl available — skipping verification."
        FOUND="skip"
    fi

    if [ "$FOUND" = "yes" ]; then
        echo_info "Release $NEW_TAG found."
    elif [ "$FOUND" = "skip" ]; then
        : # already warned
    else
        echo_warn "Could not confirm release $NEW_TAG exists (network, rate limit, or bad tag)."
        if [ "$ASSUME_YES" = false ]; then
            read -p "Continue anyway? Type 'yes': " CONFIRM
            [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }
        fi
    fi
fi

# --- Pre-flight: make sure every target file exists ---
for f in "${IMAGE_FILES[@]}" "${ANNOTATION_FILES[@]}"; do
    [ -f "$f" ] || { echo_error "Expected file not found: $f"; exit 1; }
done

# --- Count how many references we'll change, so we can fail loudly if zero ---
TOTAL_HITS=0
for f in "${IMAGE_FILES[@]}"; do
    n=$(grep -c "${IMAGE}:v[0-9.]*" "$f" || true)
    TOTAL_HITS=$((TOTAL_HITS + n))
done
for f in "${ANNOTATION_FILES[@]}"; do
    n=$(grep -cE "^[[:space:]]*version:[[:space:]]*v[0-9.]+" "$f" || true)
    TOTAL_HITS=$((TOTAL_HITS + n))
done

if [ "$TOTAL_HITS" -eq 0 ]; then
    echo_error "Found no version references to update. Has the config layout changed?"
    exit 1
fi

echo ""
echo_step "Will update $TOTAL_HITS reference(s) across ${#IMAGE_FILES[@]} image file(s) and ${#ANNOTATION_FILES[@]} overlay annotation(s)."

if [ "$ASSUME_YES" = false ]; then
    read -p "Proceed? Type 'yes': " CONFIRM
    [ "$CONFIRM" != "yes" ] && { echo_error "Cancelled"; exit 0; }
fi

# --- sed in-place, portable across macOS (BSD) and Linux (GNU) ---
sed_inplace() {
    if sed --version > /dev/null 2>&1; then
        sed -i "$@"          # GNU
    else
        sed -i '' "$@"       # BSD/macOS
    fi
}

echo ""
echo_step "Updating image tags..."
for f in "${IMAGE_FILES[@]}"; do
    sed_inplace -E "s#(${IMAGE}):v[0-9.]+#\1:${NEW_TAG}#g" "$f"
    echo_info "$f"
done

echo_step "Updating version annotations..."
for f in "${ANNOTATION_FILES[@]}"; do
    sed_inplace -E "s#^([[:space:]]*version:[[:space:]]*)v[0-9.]+#\1${NEW_TAG}#g" "$f"
    echo_info "$f"
done

# --- Verify nothing stale remains ---
echo ""
echo_step "Verifying..."
STALE=0
if [ -n "$CURRENT_TAG" ]; then
    for f in "${IMAGE_FILES[@]}" "${ANNOTATION_FILES[@]}"; do
        if grep -q "$CURRENT_TAG" "$f"; then
            echo_error "Stale reference to $CURRENT_TAG still in $f"
            STALE=$((STALE + 1))
        fi
    done
fi
if [ "$STALE" -gt 0 ]; then
    echo_error "Bump incomplete — $STALE file(s) still reference the old tag."
    exit 1
fi
echo_info "All references now point to $NEW_TAG"

# --- Show the diff if we're in a git repo ---
if command -v git > /dev/null 2>&1 && git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    echo ""
    echo_step "Changes:"
    git --no-pager diff -- "${IMAGE_FILES[@]}" "${ANNOTATION_FILES[@]}" || true
fi

echo ""
echo_info "Bumped ${CURRENT_TAG:-?} -> $NEW_TAG"
echo ""
echo "Nothing was committed or deployed. Next steps:"
echo "  1. Review the diff above"
echo "  2. Commit the change"
echo "  3. Roll out UAT first:  ./scripts/reset-specify.sh uat"
echo "  4. Then production:     ./scripts/reset-specify.sh prod"
echo ""
