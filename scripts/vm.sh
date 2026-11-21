#!/bin/bash
# Throwaway macOS VMs for testing Cairn (needs Tart: brew install openai/tools/tart).
#
#   scripts/vm.sh base      one-time: build the clean "cairn-base" VM from Apple's latest IPSW
#   scripts/vm.sh fresh     throw away "cairn-test" and clone a clean one from cairn-base
#   scripts/vm.sh stage     build Cairn.app and scan this Mac into the shared folder (read-only)
#   scripts/vm.sh run       boot cairn-test with the shared folder attached
#   scripts/vm.sh compare   diff this Mac's manifest against the VM's
#
# Inside the VM, open Finder > My Shared Files > cairn and double-click
# "Run Cairn scan.command". It writes vm.yaml next to host.yaml.
#
# The shared folder lives outside the repo (~/CairnVM/share) because it holds a
# real scan of this Mac, which must never be committed.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BASE="cairn-base"
TEST="cairn-test"
SHARE="${CAIRN_VM_SHARE:-$HOME/CairnVM/share}"
CPUS="${CAIRN_VM_CPUS:-4}"
MEMORY_MB="${CAIRN_VM_MEMORY_MB:-6144}"
DISK_GB="${CAIRN_VM_DISK_GB:-60}"

need_tart() {
    command -v tart >/dev/null || { echo "Tart isn't installed: brew install openai/tools/tart" >&2; exit 1; }
}
vm_exists() { tart list --quiet 2>/dev/null | grep -qx "$1"; }

case "${1:-}" in
base)
    need_tart
    if vm_exists "$BASE"; then echo "$BASE already exists."; exit 0; fi
    IPSW_DONE="$(ls "$HOME"/CairnVM/ipsw/*_"$(sw_vers -buildVersion)"_Restore.ipsw 2>/dev/null | head -1 || true)"
    if [ -n "$IPSW_DONE" ]; then
        echo "==> Using downloaded $(basename "$IPSW_DONE")"
        tart create "$BASE" --from-ipsw "$IPSW_DONE" --disk-size "$DISK_GB"
        tart set "$BASE" --cpu "$CPUS" --memory "$MEMORY_MB"
        echo "Next: tart run $BASE, finish Setup Assistant, shut down."
        exit 0
    fi
    # Download the IPSW ourselves: curl resumes after a dropped connection,
    # whereas `tart create --from-ipsw latest` throws away a partial download.
    # Use the build this Mac runs, so the VM matches the host.
    BUILD="$(sw_vers -buildVersion)"
    URL="$(curl -fsS https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml \
        | grep -oE "https://[^<]*_${BUILD}_Restore\.ipsw" | head -1)"
    [ -n "$URL" ] || { echo "Apple's catalog has no IPSW for build $BUILD." >&2; exit 1; }
    IPSW="$HOME/CairnVM/ipsw/$(basename "$URL")"
    mkdir -p "$(dirname "$IPSW")"
    echo "==> Downloading $(basename "$URL") (resumable; rerun to continue)"
    until curl -fL -C - --retry 10 --retry-all-errors --progress-bar -o "$IPSW.part" "$URL"; do
        echo "Download interrupted, resuming in 10 s…" >&2; sleep 10
    done
    mv "$IPSW.part" "$IPSW"
    echo "==> Creating $BASE (installs macOS into the VM; takes a while)"
    tart create "$BASE" --from-ipsw "$IPSW" --disk-size "$DISK_GB"
    tart set "$BASE" --cpu "$CPUS" --memory "$MEMORY_MB"
    cat <<EOF

Next, finish Setup Assistant once by hand:
  tart run $BASE
Create a local user, skip Apple Account sign-in for now, then shut the VM down.
Every test clones this clean state, so don't install anything in it.
EOF
    ;;
fresh)
    need_tart
    vm_exists "$BASE" || { echo "No $BASE yet. Run: scripts/vm.sh base" >&2; exit 1; }
    if vm_exists "$TEST"; then tart stop "$TEST" 2>/dev/null || true; tart delete "$TEST"; fi
    tart clone "$BASE" "$TEST"
    echo "Clean $TEST ready."
    ;;
stage)
    mkdir -p "$SHARE"
    scripts/build-app.sh
    rm -rf "$SHARE/Cairn.app" "$SHARE/vm.yaml"
    cp -R dist/Cairn.app "$SHARE/"
    # Typing into a Tart window from outside is unreliable (keys get remapped),
    # so give the VM a script it can run with a double-click in Finder.
    RUNNER="$SHARE/Run Cairn scan.command"
    cat > "$RUNNER" <<'EOF'
#!/bin/sh
# Runs inside cairn-test: read-only scan of the VM into the shared folder.
D="/Volumes/My Shared Files/cairn"
"$D/Cairn.app/Contents/MacOS/cairn" scan -o "$D/vm.yaml"
echo "exit: $?"
EOF
    chmod +x "$RUNNER"
    xattr -c "$RUNNER" 2>/dev/null || true
    echo "==> Scanning this Mac (read-only) → $SHARE/host.yaml"
    dist/Cairn.app/Contents/MacOS/cairn scan -o "$SHARE/host.yaml"
    ;;
run)
    need_tart
    vm_exists "$TEST" || { echo "No $TEST yet. Run: scripts/vm.sh fresh" >&2; exit 1; }
    mkdir -p "$SHARE"
    tart run "$TEST" --dir "cairn:$SHARE"
    ;;
compare)
    for f in host.yaml vm.yaml; do
        [ -f "$SHARE/$f" ] || { echo "Missing $SHARE/$f" >&2; exit 1; }
    done
    dist/Cairn.app/Contents/MacOS/cairn diff "$SHARE/host.yaml" "$SHARE/vm.yaml" || true
    ;;
*)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
