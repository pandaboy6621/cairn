#!/bin/bash
# Builds Cairn's Linux release files into dist/:
#   cairn_<version>_amd64.deb         install with App Center (double-click) or apt
#   Cairn-<version>-x86_64.AppImage   runs without installing; adds itself to the
#                                     app grid the first time it's opened
# plus a .sha256 for each. Runs on Ubuntu 26.04 (the release workflow uses the
# swift:latest image), needs libadwaita-1-dev, libgtk-4-dev, libsqlite3-dev,
# librsvg2-bin, dpkg-dev and desktop-file-utils, and for the AppImage `appimagetool` on PATH.
# Usage: scripts/package-linux.sh [deb|appimage|all]
set -euo pipefail
cd "$(dirname "$0")/.."
what=${1:-all}
version="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/CairnCore/Cairn.swift)"
arch=amd64
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
    size="$(du -sk "$root/usr" | cut -f1)"
    mkdir -p "$root/DEBIAN"
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
