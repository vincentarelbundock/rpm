#!/usr/bin/env bash
# Install from the built tree before it is published.
#
# This is the check that matters: an RPM repository can be perfectly
# well-formed as a directory and still be unusable because a package is
# signed by a key dnf does not accept, because repomd.xml.asc does not match,
# or because a binary needs a newer glibc than an EL release ships. Each of
# those fails here, inside a container of each distribution in VERIFY_IMAGES,
# against a file:// baseurl that goes through the same dnf code path as HTTP.
#
# Needs docker. Only this machine's architecture is checked.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
public="$root/public"

[ -f "$public/repodata/repomd.xml" ] || { echo "no built repository in public/" >&2; exit 1; }

# Fedora only, for now. EL9 (Rocky, Alma, RHEL) ships glibc 2.34, and the
# upstream binaries are built on Ubuntu 22.04 against 2.35 or newer, so
# calepin and pulpit install there but do not run. Once upstream builds
# against an older glibc, add rockylinux/rockylinux:9 here so a regression
# fails the deploy; until then, `VERIFY_IMAGES=rockylinux/rockylinux:9`
# shows the current state.
images="${VERIFY_IMAGES:-fedora:latest}"

arch="$(uname -m)"

# Package names for this architecture, from the file names createrepo_c
# indexed: <name>-<version>-<release>.<arch>.rpm.
pkgs="$(find "$public/packages" -name "*.$arch.rpm" -printf '%f\n' |
  sed -E 's/-[^-]+-[^-]+\.[^.]+\.rpm$//' | sort -u | tr '\n' ' ')"
if [ -z "$pkgs" ]; then
  echo "no packages for this machine's architecture ($arch); nothing to verify here"
  exit 0
fi

if [ -f "$public/RPM-GPG-KEY-vab" ]; then
  repo_checks="gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///repo/RPM-GPG-KEY-vab"
else
  echo "warning: unsigned repository, verifying with gpgcheck=0" >&2
  repo_checks="gpgcheck=0
repo_gpgcheck=0"
fi

status=0
for image in $images; do
  echo "=== $image"
  # The distribution's repositories stay enabled, because some packages
  # (pulpit) depend on libraries only the distribution carries. So after each
  # install, the package itself is checked to have come from this repository,
  # lest a same-named distribution package make the check pass for the wrong
  # reason.
  if ! docker run --rm -i -v "$public:/repo:ro" \
      -e PKGS="$pkgs" -e REPO_CHECKS="$repo_checks" "$image" bash -eu <<'IN_CONTAINER'
printf '[vab-verify]\nname=vab verify\nbaseurl=file:///repo\nenabled=1\n%s\n' \
  "$REPO_CHECKS" > /etc/yum.repos.d/vab-verify.repo
status=0
for pkg in $PKGS; do
  echo "--- $pkg"
  if ! dnf -y -q install "$pkg"; then
    echo "::error::$pkg failed to install from the built repository"
    status=1
    continue
  fi
  if ! dnf list --installed "$pkg" | grep -q 'vab-verify'; then
    echo "::error::$pkg was installed from somewhere other than the built repository"
    dnf list --installed "$pkg"
    status=1
  fi
  # Every package here ships exactly one command named after itself.
  if ! "$pkg" --version; then
    echo "::error::$pkg installed but does not run"
    status=1
  fi
  dnf -y -q remove "$pkg" >/dev/null
done
exit "$status"
IN_CONTAINER
  then
    status=1
  fi
done

exit "$status"
