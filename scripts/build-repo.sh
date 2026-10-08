#!/usr/bin/env bash
# Assemble the whole RPM repository into public/, ready to be deployed to
# GitHub Pages.
#
# Nothing binary is ever committed to this repository. Every .rpm is fetched
# from the upstream project's GitHub release at build time (or built here from
# the released binary, for a project that publishes no .rpm), so the source of
# truth stays in each project and this repository holds only the description
# of how to serve them.
#
# The output layout is a single flat repository covering every architecture;
# dnf reads each package's arch from repodata and ignores the ones that do
# not match the machine:
#
#   public/packages/<name>-<version>-<release>.<arch>.rpm
#   public/repodata/{repomd.xml,repomd.xml.asc,...}
#   public/vab.repo
#   public/RPM-GPG-KEY-vab
#
# Signing happens only when RPM_GPG_PRIVATE_KEY is set. Then every package is
# signed (gpgcheck) and so is repomd.xml (repo_gpgcheck). Without it the
# repository is still usable, but the .repo file has to turn both checks off,
# so an unsigned build prints a loud warning.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

public="$root/public"
work="$root/.work"
manifest="$root/projects.json"

BASEURL="https://vincentarelbundock.github.io/rpm"
REPO_ID="vab"

rm -rf "$public" "$work"
mkdir -p "$public/packages" "$work"

for tool in jq gh nfpm createrepo_c; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

note() { printf '  %s\n' "$*"; }
warn() { printf '  warning: %s\n' "$*" >&2; }

# nfpm takes Go architecture names and translates them per packager.
goarch() {
  case "$1" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    *) echo "$1" ;;
  esac
}

collected=0

project_count="$(jq '.projects | length' "$manifest")"
for i in $(seq 0 $((project_count - 1))); do
  name="$(jq -r ".projects[$i].name" "$manifest")"
  repo="$(jq -r ".projects[$i].repo" "$manifest")"
  rpm_pattern="$(jq -r ".projects[$i].rpm_pattern // empty" "$manifest")"
  nfpm_template="$(jq -r ".projects[$i].nfpm // empty" "$manifest")"

  # The latest non-draft, non-prerelease tag. A prerelease reaching users who
  # subscribed to a stable repository would be a surprise, so it is skipped.
  tag="$(gh release list --repo "$repo" --limit 20 \
          --json tagName,isDraft,isPrerelease \
          -q '[.[] | select(.isDraft == false and .isPrerelease == false)][0].tagName')"
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    warn "$name: no published release; skipping"
    continue
  fi
  version="${tag#v}"
  echo "$name $version ($repo)"

  assets="$work/$name-assets.txt"
  gh release view "$tag" --repo "$repo" --json assets -q '.assets[].name' > "$assets"

  while read -r arch triple; do
    [ -n "$arch" ] || continue
    outdir="$work/$name-$arch"
    rm -rf "$outdir"; mkdir -p "$outdir"

    if [ -n "$rpm_pattern" ]; then
      # Serve upstream's own package. The pattern carries a literal ARCH
      # placeholder so one line in projects.json covers every architecture.
      pattern="${rpm_pattern//ARCH/$arch}"
      if ! grep -qE "^${pattern//\*/.*}$" "$assets"; then
        warn "$name: no asset matching $pattern in $tag; skipping $arch"
        continue
      fi
      gh release download "$tag" --repo "$repo" \
        --pattern "$pattern" --dir "$outdir" --clobber
      found="$(find "$outdir" -maxdepth 1 -name '*.rpm' -print -quit)"
      [ -n "$found" ] || { warn "$name: download produced no .rpm for $arch"; continue; }
      cp "$found" "$public/packages/"
      note "$arch: upstream $(basename "$found")"
    else
      # Build the package here from the released binary.
      asset="$name-$triple.tar.xz"
      if ! grep -qx "$asset" "$assets"; then
        warn "$name: $tag publishes no $asset; skipping $arch"
        continue
      fi
      gh release download "$tag" --repo "$repo" \
        --pattern "$asset" --dir "$outdir" --clobber
      mkdir -p "$outdir/unpack"
      tar -xJf "$outdir/$asset" -C "$outdir/unpack" --strip-components=1
      [ -f "$outdir/unpack/$name" ] || { warn "$name: no $name binary inside $asset"; continue; }
      chmod 755 "$outdir/unpack/$name"

      # nfpm expands environment variables in scalar fields but not in
      # `contents[].src`, so the binary is staged at the fixed path each
      # template names rather than passed in as a variable.
      rm -rf "$work/staging"; mkdir -p "$work/staging"
      install -m755 "$outdir/unpack/$name" "$work/staging/$name"
      PKG_VERSION="$version" PKG_ARCH="$(goarch "$arch")" \
        nfpm package --packager rpm --config "$root/$nfpm_template" \
          --target "$public/packages/" >/dev/null
      note "$arch: built $name-$version-1.$arch.rpm from $asset"
    fi

    collected=$((collected + 1))
  done < <(jq -r ".projects[$i].arches | to_entries[] | \"\(.key) \(.value)\"" "$manifest")
done

if [ "$collected" -eq 0 ]; then
  echo "no packages were collected; refusing to publish an empty repository" >&2
  exit 1
fi

signed=0
if [ -n "${RPM_GPG_PRIVATE_KEY:-}" ]; then
  for tool in gpg rpmsign; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool for signing: $tool" >&2; exit 1; }
  done

  export GNUPGHOME="$work/gnupg"
  mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  printf '%s' "$RPM_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
  # What to sign with. The key may be a dedicated archive key exported whole,
  # or a signing subkey of a personal key exported on its own. The second
  # shape is the better one, because it keeps the primary secret out of CI.
  # It also means the primary secret is absent here, so gpg has to be pointed
  # at that exact subkey with a trailing "!" rather than choosing for itself.
  #
  # In --with-colons output, field 12 is a key's own capabilities ("s" for
  # signing) and field 15 is "+" when its secret material is actually present.
  colons="$(gpg --list-secret-keys --with-colons)"
  signkey="$(printf %s "$colons" |
    awk -F: '$1 == "ssb" && $12 ~ /s/ && $15 == "+" { print $5 "!"; exit }')"
  if [ -z "$signkey" ]; then
    signkey="$(printf %s "$colons" |
      awk -F: '$1 == "sec" && $12 ~ /s/ && $15 == "+" { print $5; exit }')"
  fi
  if [ -z "$signkey" ]; then
    echo "RPM_GPG_PRIVATE_KEY imported no key that can sign" >&2
    exit 1
  fi

  # The key users import is the whole public key, primary and subkeys, so it
  # keeps working when the signing subkey is rotated.
  primary="$(printf %s "$colons" | awk -F: '$1 == "fpr" { print $10; exit }')"

  # An expired key makes `dnf install` refuse every package, with an error
  # that does not obviously say why. Be loud about it well before it lands.
  expiry="$(printf %s "$colons" |
    awk -F: -v k="${signkey%!}" \
      '($1 == "sec" || $1 == "ssb") && $5 == k { print $7; exit }')"
  if [ -n "$expiry" ] && [ "$expiry" != "0" ]; then
    days=$(( (expiry - $(date +%s)) / 86400 ))
    if [ "$days" -lt 0 ]; then
      echo "signing key ${signkey%!} expired $(( -days )) days ago; publishing would break dnf for every user" >&2
      exit 1
    elif [ "$days" -lt 90 ]; then
      warn "signing key ${signkey%!} expires in $days days ($(date -u -d "@$expiry" +%Y-%m-%d)). Extend it, and note that users who already imported the key will need the refreshed file."
    fi
  fi

  gpgopts=(--batch --yes --quiet --local-user "$signkey")
  if [ -n "${RPM_GPG_PASSPHRASE:-}" ]; then
    gpgopts+=(--pinentry-mode loopback --passphrase "$RPM_GPG_PASSPHRASE")
  fi

  # Package signatures, so `gpgcheck=1` holds. Upstream packages arrive
  # unsigned; this adds a signature header and leaves the payload as
  # upstream's bytes. rpmsign hands the signing itself to gpg, and the extra
  # arguments carry the same options as the repomd signature below.
  # __gpg is set explicitly because Ubuntu's rpm macros name a gpg2 binary
  # that the gnupg package no longer ships.
  rpmsign --addsign \
    --define "_gpg_name ${signkey}" \
    --define "__gpg $(command -v gpg)" \
    --define "_gpg_path $GNUPGHOME" \
    --define "_gpg_digest_algo sha256" \
    --define "_gpg_sign_cmd_extra_args --batch${RPM_GPG_PASSPHRASE:+ --pinentry-mode loopback --passphrase $RPM_GPG_PASSPHRASE}" \
    "$public"/packages/*.rpm >/dev/null

  gpg --export --armor "$primary" > "$public/RPM-GPG-KEY-$REPO_ID"
  # Spaced in groups of four, the way gpg and dnf print it, so readers can
  # compare it against dnf's import prompt by eye.
  fingerprint="$(printf %s "$primary" | sed 's/.\{4\}/& /g; s/ $//')"
  signed=1
  echo "  packages signed with $signkey"
else
  cat >&2 <<'UNSIGNED'
  warning: RPM_GPG_PRIVATE_KEY is not set, so neither the packages nor the
  repository metadata are signed. The published .repo file turns gpgcheck and
  repo_gpgcheck off, which disables the only check that proves the packages
  came from this repository. See README.md for the signing key.
UNSIGNED
fi

echo
echo "Indexing"
# gzip rather than createrepo_c's default zstd: older dnf on EL8 cannot read
# zstd metadata, and the repository is small enough that size does not matter.
createrepo_c --quiet --general-compress-type=gz "$public" >/dev/null
echo "  $(find "$public/packages" -name '*.rpm' | wc -l) packages in repodata"

if [ "$signed" -eq 1 ]; then
  # Metadata signature, so `repo_gpgcheck=1` holds: without it a mirror or a
  # compromised Pages deploy could serve an older, validly signed package set.
  gpg "${gpgopts[@]}" --armor --detach-sign \
    -o "$public/repodata/repomd.xml.asc" "$public/repodata/repomd.xml"
  echo "  repomd.xml signed"
  gpgcheck=1
else
  gpgcheck=0
fi

# The .repo file users drop into /etc/yum.repos.d. Its checks follow the
# actual signing state of this build, for the same reason the landing page
# does below.
{
  echo "[$REPO_ID]"
  echo "name=CLI tools by Vincent Arel-Bundock"
  echo "baseurl=$BASEURL"
  echo "enabled=1"
  echo "gpgcheck=$gpgcheck"
  echo "repo_gpgcheck=$gpgcheck"
  [ "$signed" -eq 1 ] && echo "gpgkey=$BASEURL/RPM-GPG-KEY-$REPO_ID"
} > "$public/$REPO_ID.repo"

cd "$root"

# The landing page's install instructions depend on whether this build
# actually signed. Writing them here rather than in site/index.html means a
# page never tells readers to verify against a key that is not there, and
# never teaches them to turn verification off after it started working.
if [ "$signed" -eq 1 ]; then
  cat > "$work/install.html" <<'HTML'
<h2>Add the repository</h2>
<p>Fedora (dnf5):</p>
<pre><code>sudo dnf config-manager addrepo \
  --from-repofile=https://vincentarelbundock.github.io/rpm/vab.repo</code></pre>
<p>RHEL, Rocky, AlmaLinux and older Fedora (dnf4):</p>
<pre><code>sudo curl -fsSL -o /etc/yum.repos.d/vab.repo \
  https://vincentarelbundock.github.io/rpm/vab.repo</code></pre>
<p>dnf asks you to confirm the signing key the first time it installs from
here. Its fingerprint is
<code>@FINGERPRINT@</code>.</p>
HTML
else
  cat > "$work/install.html" <<'HTML'
<h2>Add the repository</h2>
<p class="warn"><strong>This repository is not signed yet.</strong> The
<code>.repo</code> file below turns <code>gpgcheck</code> off, which tells dnf
to accept the packages without verifying where they came from. If you would
rather not do that, download the <code>.rpm</code> you want from the project's
own releases page instead.</p>
<pre><code>sudo curl -fsSL -o /etc/yum.repos.d/vab.repo \
  https://vincentarelbundock.github.io/rpm/vab.repo</code></pre>
HTML
fi

[ "$signed" -eq 1 ] && sed -i "s/@FINGERPRINT@/$fingerprint/" "$work/install.html"

# Splice it in, then drop the placeholder line itself.
awk -v f="$work/install.html" '
  /<!--INSTALL-SNIPPET-->/ { while ((getline line < f) > 0) print line; next }
  { print }
' site/index.html > "$public/index.html"

rm -rf "$work"

echo
echo "Repository assembled in public/"
find "$public/packages" -name '*.rpm' -printf '  %f\n' | sort
