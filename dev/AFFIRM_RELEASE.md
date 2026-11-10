# Building and publishing the Affirm Airflow fork

`dev/affirm-release.sh` builds `apache-airflow` (version from `__version__` in
`airflow/__init__.py`, e.g. `2.9.3+affirm1`) and uploads it to Affirm's
Artifactory PyPI repository with twine.

## Prerequisites

- Python 3.8–3.12 available (the script picks `/pyenv/versions/3.12.*` or `3.9.*` by default).
  It creates a tooling venv at `~/venvs/airflow-release` with hatch, twine and pre-commit.
- Network access: the build downloads node/yarn (via pre-commit) to compile the UI assets.
- A `~/.pypirc` (below) for uploading.

## `~/.pypirc`

```ini
[distutils]
index-servers = pypi-local

[pypi-local]
repository: https://affirmprod.jfrog.io/artifactory/api/pypi/pypi-local
username: <your-artifactory-username>
password: <your-artifactory-api-key-or-identity-token>
```

`username`/`password` are optional; if omitted, twine prompts for them (or reads
`TWINE_USERNAME`/`TWINE_PASSWORD`). Keep the file private: `chmod 600 ~/.pypirc`.

## Releasing

1. Bump `__version__` in `airflow/__init__.py` (e.g. `2.9.3+affirm2`). Artifactory
   won't let you overwrite an existing version.
2. Commit. The build refuses a dirty working tree, and upload refuses any wheel that
   wasn't built cleanly from the current `HEAD`.
3. Build and publish:

```bash
dev/affirm-release.sh build              # build wheel + sdist into dist/
dev/affirm-release.sh upload --dry-run   # show what would be published, and where
dev/affirm-release.sh upload             # publish (asks for confirmation)
# or both in one go:
dev/affirm-release.sh build-upload
```

Before uploading, the script prints the package, version, commit, files and the
repository URL from `~/.pypirc`, then asks `Proceed? [y/N]`.

Run `dev/affirm-release.sh --help` for all options (`--repo`, `--venv`, `--python`,
`--no-clean`, `--allow-dirty`, `--force`, `--yes`).
