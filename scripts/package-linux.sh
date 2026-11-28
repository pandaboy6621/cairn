#!/bin/bash
# Builds Cairn's Linux release files into dist/:
#   cairn_<version>_amd64.deb         install with App Center (double-click) or apt
#   Cairn-<version>-x86_64.AppImage   runs without installing; adds itself to the
#                                     app grid the first time it's opened
# plus a .sha256 for each. Runs on Ubuntu 26.04 (the release workflow uses the
# swift:latest image), needs libadwaita-1-dev, libgtk-4-dev, libsqlite3-dev,
# librsvg2-bin, dpkg-dev, desktop-file-utils and gnupg, and for the AppImage `appimagetool` on PATH.
# Usage: scripts/package-linux.sh [deb|appimage|all]
set -euo pipefail
cd "$(dirname "$0")/.."
what=${1:-all}
version="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/CairnCore/Cairn.swift)"
arch=amd64
# Where Cairn's apt repository is published (GitHub Pages, by linux.yml).
APT_URL=https://pandaboy6621.github.io/cairn/apt
mkdir -p dist

# Static Swift runtime: the binaries need only the system's own libraries.
swift build -c release --static-swift-stdlib --product cairn-gnome
swift build -c release --static-swift-stdlib --product cairn
bin="$(swift build -c release --show-bin-path)"

stage() { # root folder: the files both packages share, below <root>/usr
    local root=$1
    install -Dm755 "$bin/cairn-gnome" "$root/usr/bin/cairn-gnome"
    install -Dm755 "$bin/cairn" "$root/usr/bin/cairn"
    # Debug symbols are most of their size.
    strip --strip-unneeded "$root/usr/bin/cairn-gnome" "$root/usr/bin/cairn"
    install -Dm644 linux/dev.cairn.Cairn.desktop "$root/usr/share/applications/dev.cairn.Cairn.desktop"
    install -Dm644 linux/dev.cairn.Cairn.svg "$root/usr/share/icons/hicolor/scalable/apps/dev.cairn.Cairn.svg"
    for size in 48 128 256; do
        mkdir -p "$root/usr/share/icons/hicolor/${size}x${size}/apps"
        rsvg-convert -w $size -h $size linux/dev.cairn.Cairn.svg -o "$root/usr/share/icons/hicolor/${size}x${size}/apps/dev.cairn.Cairn.png"
    done
    sed "s/@VERSION@/$version/; s/@DATE@/$(date -u +%Y-%m-%d)/" linux/dev.cairn.Cairn.metainfo.xml \
        | install -Dm644 /dev/stdin "$root/usr/share/metainfo/dev.cairn.Cairn.metainfo.xml"
    # Debian's machine-readable copyright file; the full license is on every Debian system.
    install -Dm644 /dev/stdin "$root/usr/share/doc/cairn/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Cairn
Source: https://github.com/pandaboy6621/cairn

Files: *
Copyright: Cairn contributors
License: GPL-3.0+
 This program is free software: you can redistribute it and/or modify it
 under the terms of the GNU General Public License as published by the Free
 Software Foundation, either version 3 of the License, or (at your option)
 any later version.
 .
 On Debian systems, the full text of the GNU General Public License version 3
 can be found in /usr/share/common-licenses/GPL-3.
COPYRIGHT
}

sha() { (cd dist && sha256sum "$1" > "$1.sha256"); }

if [ "$what" = deb ] || [ "$what" = all ]; then
    root="$(mktemp -d)/cairn"
    stage "$root"
    # Which system packages the binaries need, worked out from their libraries.
    work="$(mktemp -d)"
    mkdir -p "$work/debian"
    printf 'Source: cairn\n\nPackage: cairn\nArchitecture: any\n' > "$work/debian/control"
    depends="$(cd "$work" && dpkg-shlibdeps -O -e "$root/usr/bin/cairn-gnome" -e "$root/usr/bin/cairn" 2>/dev/null \
        | sed -n 's/^shlibs:Depends=//p')"
    [ -n "$depends" ] || { echo "dpkg-shlibdeps found no dependencies" >&2; exit 1; }
    # Cairn's apt repository, so the installed .deb updates with Software Updater
    # (like Chrome's and Brave's): its public key and a sources file. The sources file
    # is a conffile, so a user who removes or edits it keeps their choice.
    if [ -f linux/cairn-archive-keyring.asc ]; then
        install -d "$root/usr/share/keyrings" "$root/etc/apt/sources.list.d"
        gpg --dearmor < linux/cairn-archive-keyring.asc > "$root/usr/share/keyrings/cairn-archive-keyring.gpg"
        chmod 644 "$root/usr/share/keyrings/cairn-archive-keyring.gpg"
        cat > "$root/etc/apt/sources.list.d/cairn.sources" <<SOURCES
Types: deb
URIs: $APT_URL
Suites: stable
Components: main
Architectures: $arch
Signed-By: /usr/share/keyrings/cairn-archive-keyring.gpg
SOURCES
        chmod 644 "$root/etc/apt/sources.list.d/cairn.sources"
    fi
    size="$(du -sk "$root" | cut -f1)"
    mkdir -p "$root/DEBIAN"
    [ -f "$root/etc/apt/sources.list.d/cairn.sources" ] && echo /etc/apt/sources.list.d/cairn.sources > "$root/DEBIAN/conffiles"
    cat > "$root/DEBIAN/control" <<CONTROL
Package: cairn
Version: $version
Architecture: $arch
Maintainer: Cairn <66539261+pandaboy6621@users.noreply.github.com>
Installed-Size: $size
Depends: $depends
Section: utils
Priority: optional
Homepage: https://github.com/pandaboy6621/cairn
Description: Back up and restore a computer's setup, not its files
 Cairn records which apps, software sources, settings and config files this
 computer has, and sets up another computer the same way. Restoring always
 shows what would change first. Includes the GNOME app and the cairn command.
CONTROL
    deb="cairn_${version}_${arch}.deb"
    dpkg-deb --root-owner-group -Zxz --build "$root" "dist/$deb" >/dev/null
    sha "$deb"
    echo "Built dist/$deb"
fi

if [ "$what" = appimage ] || [ "$what" = all ]; then
    appdir="$(mktemp -d)/Cairn.AppDir"
    stage "$appdir"
    cp linux/dev.cairn.Cairn.desktop "$appdir/dev.cairn.Cairn.desktop"
    cp linux/dev.cairn.Cairn.svg "$appdir/dev.cairn.Cairn.svg"
    cp "$appdir/usr/share/icons/hicolor/256x256/apps/dev.cairn.Cairn.png" "$appdir/.DirIcon"
    cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
here="$(dirname "$(readlink -f "$0")")"
exec "$here/usr/bin/cairn-gnome" "$@"
APPRUN
    chmod 755 "$appdir/AppRun"
    image="Cairn-${version}-x86_64.AppImage"
    # No FUSE in a container: appimagetool (itself an AppImage) extracts and runs.
    APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 appimagetool --no-appstream "$appdir" "dist/$image"
    sha "$image"
    echo "Built dist/$image"
fi
