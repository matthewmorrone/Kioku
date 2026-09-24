#!/usr/bin/env python3
"""Give every tracked file (repo + submodules) an mtime derived from its content hash.

CI only. A fresh checkout stamps every file with the checkout time, so a DerivedData cache restored
from another run sees every source as modified and recompiles all of it. Deriving the mtime from the
git blob hash makes it identical across checkouts for unchanged content and different for changed
content, without needing git history (checkout is shallow). Paired with the XCBuild
IgnoreFileSystemDeviceInodeChanges default, since a new checkout also gives every file a new inode.
"""
import os
import subprocess
import sys

# 2001-01-01 plus up to ~3 years: always in the past, so no tool treats a source as newer than its
# restored build products merely because of this stamp.
BASE_EPOCH = 978307200
SPAN_SECONDS = 100_000_000


# Lists (path, blob sha) for every tracked regular file under `repo`, so each can be stamped.
def tracked_blobs(repo):
    out = subprocess.run(["git", "-C", repo, "ls-files", "-s", "-z"],
                         check=True, capture_output=True).stdout
    for record in out.split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, sha, _stage = meta.split(b" ")
        # 160000 is a submodule gitlink; its files are stamped by the submodule pass.
        if mode == b"160000":
            continue
        yield os.path.join(repo, os.fsdecode(path)), sha.decode()


# Lists the checked-out submodule roots, so their sources (local SPM packages) are stamped too.
def submodule_roots(repo):
    out = subprocess.run(["git", "-C", repo, "submodule", "foreach", "--quiet", "--recursive",
                          "echo $toplevel/$sm_path"],
                         check=True, capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line]


# Stamps every tracked file in the repo and its submodules and reports how many were touched.
def main():
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    count = 0
    for repo in [root] + submodule_roots(root):
        for path, sha in tracked_blobs(repo):
            # A tracked symlink is stamped on the link itself, never on its target.
            if not os.path.lexists(path):
                continue
            stamp = BASE_EPOCH + int(sha[:12], 16) % SPAN_SECONDS
            os.utime(path, (stamp, stamp), follow_symlinks=False)
            count += 1
    print(f"Pinned mtimes of {count} tracked files to their content hashes")


if __name__ == "__main__":
    main()
