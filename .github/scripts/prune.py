#!/usr/bin/env python3
"""Removes library files no index uses, and the content anchors only they kept alive.

usage: prune.py <prefix> [--apply]

<prefix> is relative to the library base, e.g. `en/library/character/member/`. Every object
under it is deleted. ripper links each library file to an anchor `.blobs/<md5>-<size>` on the
SeaweedFS filer (SekaiStoryRipper ADR-0019); deleting a path gives up its share, and the data
is freed only when the anchor goes too. So an anchor is deleted as well when no path outside
the prefix has the same content (ETag and size). Deleting a path never harms the other links
of its content (ADR-0019's measurements), so a shared anchor is merely kept.

Without --apply it only prints what it would delete. The caller must make sure no episode
index references the prefix; run it in the `rip` concurrency group, so that no rip links to
these anchors meanwhile.
"""

import json
import os
import re
import subprocess
import sys
from collections import defaultdict

BUCKET = "sekai-extra-assets"
ROOT = "sekai-story/ripper/"
BLOBS = ROOT + ".blobs/"


def aws(*args):
    result = subprocess.run(["aws", *args, "--output", "json"], check=True, capture_output=True, text=True)
    return json.loads(result.stdout) if result.stdout.strip() else {}


def list_objects(prefix):
    """Every object under `prefix`: key -> (etag, size)."""
    objects = {}
    token = None
    while True:
        args = ["s3api", "list-objects-v2", "--no-paginate", "--bucket", BUCKET, "--prefix", prefix]
        args += ["--max-keys", "1000"]
        if token:
            args += ["--continuation-token", token]
        page = aws(*args)
        for item in page.get("Contents", []):
            objects[item["Key"]] = (item["ETag"].strip('"'), int(item["Size"]))
        token = page.get("NextContinuationToken")
        if not token:
            return objects


def delete(keys):
    for start in range(0, len(keys), 1000):
        batch = keys[start : start + 1000]
        body = json.dumps({"Objects": [{"Key": k} for k in batch], "Quiet": True})
        result = aws("s3api", "delete-objects", "--bucket", BUCKET, "--delete", body)
        errors = result.get("Errors", [])
        if errors:
            sys.exit(f"delete failed: {errors[:5]}")
        print(f"  deleted {start + len(batch)} of {len(keys)}", flush=True)


def main():
    args = [a for a in sys.argv[1:] if a != "--apply"]
    apply = "--apply" in sys.argv[1:]
    if len(args) != 1 or not re.fullmatch(r"(jp|en|cn|tw|kr)/library/(?!_index/)[^.][^\s]*/", args[0]):
        sys.exit("prefix must be <region>/library/<path>/ (not _index)")
    target = ROOT + args[0]

    print(f"listing {ROOT} ...", flush=True)
    everything = list_objects(ROOT)
    files = {k: v for k, v in everything.items() if k.startswith(target)}
    if not files:
        sys.exit(f"nothing under {target}")
    holders = defaultdict(list)
    for key, content in everything.items():
        holders[content].append(key)

    anchors, shared = [], []
    for content in sorted(set(files.values())):
        etag, size = content
        anchor = f"{BLOBS}{etag}-{size}"
        others = [k for k in holders[content] if not k.startswith(target) and k != anchor]
        if anchor not in everything:
            continue
        if others:
            shared.append((anchor, others[:3]))
        else:
            anchors.append(anchor)

    total = sum(size for _, size in files.values())
    freed = sum(everything[a][1] for a in anchors)
    print(f"{len(everything)} objects listed")
    print(f"{len(files)} files under {target}: {total / 1e9:.2f} GB")
    print(f"{len(anchors)} anchors only they use: {freed / 1e9:.2f} GB freed after the filer's vacuum")
    print(f"{len(shared)} anchors other paths share (kept)")
    for anchor, others in shared[:20]:
        print(f"  kept {anchor}: also {', '.join(others)}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(f"### prune `{args[0]}`{'' if apply else ' (dry run)'}\n\n")
            f.write(f"- {len(files)} files, {total / 1e9:.2f} GB\n")
            f.write(f"- {len(anchors)} anchors deleted with them ({freed / 1e9:.2f} GB), {len(shared)} shared anchors kept\n")
    if not apply:
        print("dry run: nothing deleted (run with apply to delete)")
        return

    print("deleting the files ...", flush=True)
    delete(sorted(files))
    left = list_objects(target)
    if left:
        sys.exit(f"{len(left)} files are still under {target}; anchors left alone")
    print("deleting the anchors ...", flush=True)
    delete(anchors)
    print("done")


if __name__ == "__main__":
    main()
