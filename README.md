# vab RPM repository

A DNF/YUM repository for a few of my command-line tools, served from GitHub
Pages. Install instructions: <https://vincentarelbundock.github.io/rpm>.
The Debian/Ubuntu counterpart is
[vincentarelbundock/apt](https://github.com/vincentarelbundock/apt).

Nothing binary is committed here. On every run, `scripts/build-repo.sh` reads
`projects.json`, fetches each project's latest stable release from GitHub,
signs the packages, indexes them with `createrepo_c`, signs `repomd.xml`, and
the workflow deploys the result to Pages.

## Adding a package

Add an entry to `projects.json`, in one of two forms:

- **`rpm_pattern`**: the project's releases already include an `.rpm`. Give
  the asset name with a literal `ARCH` placeholder (`x86_64`, `aarch64`).
  Preferred, because the project's own dependency declarations are kept.
- **`nfpm`**: the project only publishes cargo-dist tarballs. Write a
  template under `packaging/` and point `nfpm` at it.

Push to `main`; the workflow rebuilds and redeploys. After that, new upstream
versions appear via the nightly cron, or within minutes if the project's
release workflow sends a `repository_dispatch` of type `upstream-release`.
Drafts and prereleases are skipped.

## Signing

The same key as the apt repository: the signing subkey of
`D87F 0902 9A47 8448 132D 1E1A 0266 1C78 C999 67CA` (no passphrase). The
`RPM_GPG_PRIVATE_KEY` actions secret holds that subkey alone (exported with a
trailing `!`); the primary stays in the offline backup. Packages are signed
(`gpgcheck=1`) and so is `repodata/repomd.xml` (`repo_gpgcheck=1`). Without
the secret, the build publishes unsigned with a loud warning, and the
generated `vab.repo` turns both checks off.

## Testing locally

`scripts/build-repo.sh` needs `jq`, `gh`, `nfpm` and `createrepo_c`, plus
`gpg` and `rpmsign` when signing. `scripts/verify-repo.sh` then installs every
package for the host architecture from the built tree over `file://`, inside
a Fedora container (set `VERIFY_IMAGES` to a space-separated list of images
to check others), so it needs `docker`. CI runs both.

## EL9 support

Not yet. Rocky, Alma and RHEL 9 ship glibc 2.34, and calepin, pulpit,
dadrock and dadrock-desktop are built against 2.35 or newer, so they install
there but fail at startup. scrutin works. The fix belongs upstream (build the
Linux binaries against an older glibc); once it lands, add
`rockylinux/rockylinux:9` to the default `VERIFY_IMAGES` in
`scripts/verify-repo.sh`.
