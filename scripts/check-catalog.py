#!/usr/bin/env python3
"""Checks every id in PackageCatalog.swift against the real registries.

winget ids against microsoft/winget-pkgs (needs the `gh` CLI, signed in),
Flathub ids against Flathub's API, apt names against Ubuntu's current LTS, and
dnf names against Fedora (rawhide and the newest release). Read-only: only
public package names are sent. Prints the ones that weren't found.

    python3 -I scripts/check-catalog.py
"""
import lzma, re, subprocess, sys, urllib.error, urllib.request
from functools import cache
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "Sources/CairnCore/Platforms/PackageCatalog.swift"
# Ubuntu's newest LTS. Read from its package lists (packages.ubuntu.com returns
# error pages for new releases, which looked like "found").
UBUNTU = "resolute"
FEDORA = ["rawhide", "f43"]


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "cairn-catalog-check"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception as e:  # offline, DNS...
        return -1, str(e)


@cache
def ubuntu_names():
    names = set()
    for suite in (UBUNTU, UBUNTU + "-updates"):
        for comp in ("main", "universe"):
            url = f"http://archive.ubuntu.com/ubuntu/dists/{suite}/{comp}/binary-amd64/Packages.xz"
            req = urllib.request.Request(url, headers={"User-Agent": "cairn-catalog-check"})
            with urllib.request.urlopen(req, timeout=120) as r:
                text = lzma.decompress(r.read()).decode("utf-8", "replace")
            names.update(re.findall(r"^Package: (\S+)$", text, re.M))
    return names


def found(kind, name):
    if kind == "winget":
        path = f"manifests/{name[0].lower()}/{name.replace('.', '/')}"
        r = subprocess.run(["gh", "api", f"repos/microsoft/winget-pkgs/contents/{path}", "--silent"], capture_output=True)
        return r.returncode == 0
    if kind == "flatpak":
        return get(f"https://flathub.org/api/v2/appstream/{name}")[0] == 200
    if kind == "apt":
        return name in ubuntu_names()
    if kind == "dnf":
        return any(get(f"https://mdapi.fedoraproject.org/{b}/pkg/{name}")[0] == 200 for b in FEDORA)
    return False


def main():
    text = CATALOG.read_text()
    ids = sorted({(k, m) for k in ("winget", "apt", "dnf", "flatpak") for m in re.findall(k + r': "([^"]+)"', text)})
    ubuntu_names()  # once, before the threads
    with ThreadPoolExecutor(8) as ex:
        missing = [i for i, ok in zip(ids, ex.map(lambda i: found(*i), ids)) if not ok]
    for kind, name in missing:
        print(f"not found: {kind} {name}")
    print(f"checked {len(ids)}, not found {len(missing)}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
