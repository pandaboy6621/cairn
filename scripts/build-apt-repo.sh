#!/bin/bash
# Builds Cairn's signed apt repository into site/apt from the .deb files given,
# for GitHub Pages (https://pandaboy6621.github.io/cairn/apt):
#   pool/main/cairn_<v>_amd64.deb, dists/stable/{InRelease,Release,Release.gpg},
#   dists/stable/main/binary-amd64/Packages(.gz), and the public key.
# Signs with the key in $APT_SIGNING_KEY (armored, from a repository secret),
# imported into a throwaway keyring that's deleted afterwards.
# Usage: APT_SIGNING_KEY=... scripts/build-apt-repo.sh site cairn_*.deb
set -euo pipefail
cd "$(dirname "$0")/.."
site=$1; shift
[ -n "${APT_SIGNING_KEY:-}" ] || { echo "APT_SIGNING_KEY isn't set" >&2; exit 1; }
repo="$site/apt"
rm -rf "$repo"
mkdir -p "$repo/pool/main" "$repo/dists/stable/main/binary-amd64"
for deb in "$@"; do cp "$deb" "$repo/pool/main/"; done
cp linux/cairn-archive-keyring.asc "$repo/cairn-archive-keyring.asc"

(cd "$repo" && apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages)
gzip -9kn "$repo/dists/stable/main/binary-amd64/Packages"
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=Cairn \
    -o APT::FTPArchive::Release::Label=Cairn \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="Cairn: back up and restore a computer's setup" \
    release "$repo/dists/stable" > "$repo/dists/stable/Release.tmp"
mv "$repo/dists/stable/Release.tmp" "$repo/dists/stable/Release"

export GNUPGHOME="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME"' EXIT
chmod 700 "$GNUPGHOME"
printf '%s\n' "$APT_SIGNING_KEY" | gpg --batch --quiet --import
key="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }')"
gpg --batch --yes --local-user "$key" --clearsign -o "$repo/dists/stable/InRelease" "$repo/dists/stable/Release"
gpg --batch --yes --local-user "$key" --armor --detach-sign -o "$repo/dists/stable/Release.gpg" "$repo/dists/stable/Release"
# The published key has to be the one that signs.
gpg --batch --import linux/cairn-archive-keyring.asc 2>/dev/null
gpg --batch --verify "$repo/dists/stable/Release.gpg" "$repo/dists/stable/Release"

cat > "$site/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Cairn for Linux</title>
<h1>Cairn for Linux</h1>
<p>Download the .deb from the <a href="https://github.com/pandaboy6621/cairn/releases/latest">latest release</a>
and open it: App Center installs Cairn, and Software Updater keeps it up to date from this repository.</p>
<p>Or add the repository yourself:</p>
<pre>sudo curl -fsSLo /usr/share/keyrings/cairn-archive-keyring.asc https://pandaboy6621.github.io/cairn/apt/cairn-archive-keyring.asc
echo "deb [signed-by=/usr/share/keyrings/cairn-archive-keyring.asc] https://pandaboy6621.github.io/cairn/apt stable main" | sudo tee /etc/apt/sources.list.d/cairn.list
sudo apt update &amp;&amp; sudo apt install cairn</pre>
HTML
echo "Built $repo with $(ls "$repo/pool/main" | wc -l) package(s)"
