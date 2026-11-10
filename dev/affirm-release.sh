#!/usr/bin/env bash
#
# Build and/or publish the Affirm Airflow fork (apache-airflow X.Y.Z+affirmN)
# to Affirm's Artifactory PyPI repository.
#
# Usage:
#   dev/affirm-release.sh build          [options]   # build wheel + sdist into dist/
#   dev/affirm-release.sh build-upload   [options]   # build, then upload
#   dev/affirm-release.sh upload         [options]   # upload what's already in dist/
#
# Run with --help for the options.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"

# Defaults (overridable via flags or env)
VENV_DIR="${AFFIRM_RELEASE_VENV:-${HOME}/venvs/airflow-release}"
PYTHON_BIN="${AFFIRM_RELEASE_PYTHON:-}"
TWINE_REPO="${AFFIRM_RELEASE_REPO:-pypi-local}"
PYPIRC="${AFFIRM_RELEASE_PYPIRC:-${HOME}/.pypirc}"
CLEAN=1
ALLOW_DIRTY=0
FORCE=0
ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") <build|build-upload|upload> [options]

Commands:
  build           Build the wheel and sdist into dist/ (compiles the www assets).
  build-upload    Build, then upload to the twine repository.
  upload          Upload the existing dist/ artifacts for the current version.

Options:
  -r, --repo NAME       twine repository from ~/.pypirc (default: ${TWINE_REPO})
  -p, --python PATH     Python 3.8-3.12 interpreter used to create the tooling venv
                        (default: first of /pyenv/versions/3.12.*, 3.9.*, python3)
      --venv DIR        venv that holds hatch + twine (default: ${VENV_DIR})
      --no-clean        Don't wipe the compiled www assets and node_modules first (faster)
      --allow-dirty     Allow building from a working tree with uncommitted changes
      --force           Upload even if the artifacts weren't built from a clean HEAD
  -y, --yes             Don't ask for confirmation before uploading
  -n, --dry-run         Do every check but print the upload command instead of running it
  -h, --help            Show this help

Environment overrides: AFFIRM_RELEASE_VENV, AFFIRM_RELEASE_PYTHON, AFFIRM_RELEASE_REPO,
AFFIRM_RELEASE_PYPIRC (default: ~/.pypirc). See dev/AFFIRM_RELEASE.md.

The version comes from __version__ in airflow/__init__.py. Bump it before
building a new release; Artifactory won't let you overwrite an existing version.
EOF
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- arg parsing

[[ $# -gt 0 ]] || { usage; exit 1; }

COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        build|build-upload|upload)
            [[ -z "${COMMAND}" ]] || die "Only one command allowed (got '${COMMAND}' and '$1')"
            COMMAND="$1" ;;
        -r|--repo)     [[ $# -ge 2 ]] || die "$1 needs a value"; TWINE_REPO="$2"; shift ;;
        -p|--python)   [[ $# -ge 2 ]] || die "$1 needs a value"; PYTHON_BIN="$2"; shift ;;
        --venv)        [[ $# -ge 2 ]] || die "$1 needs a value"; VENV_DIR="$2"; shift ;;
        --no-clean)    CLEAN=0 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --force)       FORCE=1 ;;
        -y|--yes)      ASSUME_YES=1 ;;
        -n|--dry-run)  DRY_RUN=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
done
[[ -n "${COMMAND}" ]] || die "Missing command: build, build-upload or upload (see --help)"

cd "${REPO_ROOT}"

# ---------------------------------------------------------------- helpers

airflow_version() {
    sed -n 's/^__version__ = "\(.*\)"$/\1/p' airflow/__init__.py
}

VERSION="$(airflow_version)"
[[ -n "${VERSION}" ]] || die "Couldn't read __version__ from airflow/__init__.py"
WHEEL="${DIST_DIR}/apache_airflow-${VERSION}-py3-none-any.whl"
SDIST="${DIST_DIR}/apache_airflow-${VERSION}.tar.gz"
HEAD_SHA="$(git rev-parse HEAD)"

pick_python() {
    if [[ -n "${PYTHON_BIN}" ]]; then
        echo "${PYTHON_BIN}"; return
    fi
    local candidate
    for candidate in /pyenv/versions/3.12.*/bin/python /pyenv/versions/3.9.*/bin/python \
                     "${HOME}"/.pyenv/versions/3.12.*/bin/python "${HOME}"/.pyenv/versions/3.9.*/bin/python; do
        [[ -x "${candidate}" ]] && { echo "${candidate}"; return; }
    done
    command -v python3 || die "No Python found; pass --python"
}

ensure_tooling() {
    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        local py
        py="$(pick_python)"
        "${py}" -c 'import sys; sys.exit(0 if (3, 8) <= sys.version_info[:2] <= (3, 12) else 1)' \
            || die "${py} is $("${py}" --version 2>&1); Airflow 2.9 needs Python 3.8-3.12 (use --python)"
        log "Creating tooling venv ${VENV_DIR} with $("${py}" --version 2>&1)"
        "${py}" -m venv "${VENV_DIR}"
    fi
    # pre-commit is needed by the build: hatch_build.py compiles the www assets with
    # `pre-commit run compile-www-assets`, and .pre-commit-config.yaml needs >= 3.2.
    # Stay below 4: pre-commit 4 deprecates the `commit`/`push` stage names that
    # upstream's .pre-commit-config.yaml still uses, and a later release may reject them.
    if ! "${VENV_DIR}/bin/python" - <<'PY' 2>/dev/null
import hatch, twine
from importlib.metadata import version
from packaging.version import Version
assert Version("3.2.0") <= Version(version("pre-commit")) < Version("4")
PY
    then
        log "Installing hatch, twine and pre-commit into ${VENV_DIR}"
        "${VENV_DIR}/bin/python" -m pip install --quiet --upgrade pip hatch twine "pre-commit>=3.2.0,<4"
    fi
    # Put the venv first on PATH so the build's subprocesses use its pre-commit and
    # python3, not whatever pyenv shims are on PATH (the default pyenv python is 3.7).
    export PATH="${VENV_DIR}/bin:${PATH}"
    HATCH="${VENV_DIR}/bin/hatch"
    TWINE="${VENV_DIR}/bin/twine"
}

# Prints the airflow/git_version baked into the wheel.
wheel_git_version() {
    "${VENV_DIR}/bin/python" - "${WHEEL}" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as zf:
    try:
        print(zf.read("airflow/git_version").decode().strip())
    except KeyError:
        print("")
PY
}

# $1 = "build" or "upload". A git_version mismatch only blocks an upload.
check_artifacts() {
    local stage="$1"
    [[ -f "${WHEEL}" ]] || die "Missing ${WHEEL#"${REPO_ROOT}"/} (run the build command first, or check __version__)"
    [[ -f "${SDIST}" ]] || die "Missing ${SDIST#"${REPO_ROOT}"/} (run the build command first, or check __version__)"

    log "Running twine check"
    "${TWINE}" check --strict "${WHEEL}" "${SDIST}"

    local git_version expected=".release:${HEAD_SHA}"
    git_version="$(wheel_git_version)"
    if [[ "${git_version}" != "${expected}" ]]; then
        local msg="Wheel git_version is '${git_version}', expected '${expected}' (clean build of HEAD)"
        if [[ "${stage}" == "build" ]]; then
            warn "${msg}; upload will refuse this build unless you pass --force"
        elif [[ ${FORCE} -eq 1 ]]; then
            warn "${msg}; continuing because of --force"
        else
            die "${msg}. Rebuild, or pass --force to upload anyway."
        fi
    fi

    "${VENV_DIR}/bin/python" - "${WHEEL}" <<'PY' || die "Wheel is missing the compiled www assets (airflow/www/static/dist)"
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as zf:
    sys.exit(0 if any(n.startswith("airflow/www/static/dist/") for n in zf.namelist()) else 1)
PY
}

# ---------------------------------------------------------------- commands

do_build() {
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        if [[ ${ALLOW_DIRTY} -eq 1 ]]; then
            warn "Working tree has uncommitted changes; the wheel will be marked .dirty and won't be uploadable without --force"
        else
            git status --short --untracked-files=no >&2
            die "Working tree has uncommitted changes. Commit them, or pass --allow-dirty."
        fi
    fi

    log "Building apache-airflow ${VERSION} from $(git rev-parse --abbrev-ref HEAD) @ ${HEAD_SHA:0:10}"
    rm -rf "${DIST_DIR}"
    local clean_flag=()
    [[ ${CLEAN} -eq 1 ]] && clean_flag=(-c)
    "${HATCH}" build ${clean_flag[@]+"${clean_flag[@]}"} -t custom -t wheel -t sdist

    check_artifacts build
    log "Built:"
    ls -lh "${WHEEL}" "${SDIST}"
}

# Prints the repository URL for $TWINE_REPO from the .pypirc, or nothing if it isn't defined.
repository_url() {
    "${VENV_DIR}/bin/python" - "${PYPIRC}" "${TWINE_REPO}" <<'PY'
import configparser, sys
cfg = configparser.RawConfigParser()
cfg.read(sys.argv[1])
print(cfg.get(sys.argv[2], "repository", fallback=""))
PY
}

do_upload() {
    check_artifacts upload

    [[ -f "${PYPIRC}" ]] || die "${PYPIRC} not found (see dev/AFFIRM_RELEASE.md for the format)"
    local url
    url="$(repository_url)"
    [[ -n "${url}" ]] || die "No [${TWINE_REPO}] section with a 'repository' URL in ${PYPIRC} (see dev/AFFIRM_RELEASE.md)"

    echo
    echo "About to publish:"
    printf '  %-11s %s\n' "package" "apache-airflow ${VERSION}"
    printf '  %-11s %s\n' "commit" "${HEAD_SHA:0:10} ($(git rev-parse --abbrev-ref HEAD))"
    printf '  %-11s %s (%s)\n' "files" "$(basename "${WHEEL}")" "$(du -h "${WHEEL}" | cut -f1)"
    printf '  %-11s %s (%s)\n' "" "$(basename "${SDIST}")" "$(du -h "${SDIST}" | cut -f1)"
    printf '  %-11s %s -> %s\n' "repository" "${TWINE_REPO}" "${url}"
    echo

    local cmd=("${TWINE}" upload --config-file "${PYPIRC}" --repository "${TWINE_REPO}" "${WHEEL}" "${SDIST}")
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "Dry run; would run:"
        printf '  %q' "${cmd[@]}"; echo
        return
    fi

    if [[ ${ASSUME_YES} -ne 1 ]]; then
        [[ -t 0 ]] || die "Not a terminal; pass --yes to upload non-interactively"
        local answer
        read -r -p "Proceed? [y/N] " answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "Aborted"
    fi

    log "Uploading to ${url}"
    "${cmd[@]}"
    log "Uploaded apache-airflow ${VERSION} to ${url}"
}

ensure_tooling

case "${COMMAND}" in
    build)        do_build ;;
    build-upload) do_build; do_upload ;;
    upload)       do_upload ;;
esac
