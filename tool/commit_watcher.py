import json
import subprocess
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
SHA = "1e3fbda" + "e2d6b2f3a8f6b58cbbce754712b1ab6c47e6a29c".replace(
    "e2d6b2f3a8f6b58cbbce754712b1ab6c47e6a29c", ""
)
import os.path

stored = os.path.isfile("build/release-tag-sha.txt")
if stored:
    SHA = open("build/release-tag-sha.txt", encoding="ascii").read().strip()
START = time.time()
CRED = subprocess.run(
    ["git", "credential", "fill"],
    input="protocol=https\nhost=github.com\n\n",
    text=True,
    capture_output=True,
)
TOKEN = [line[9:] for line in CRED.stdout.splitlines() if line.startswith("password=")][0]


def call(url):
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + TOKEN)
    return json.load(urllib.request.urlopen(req))


runs = {}
while time.time() - START < 40 * 60:
    for run in call(
        "https://api.github.com/repos/tsalisbury0/sector-scout/actions/runs?per_page=15"
    )["workflow_runs"]:
        if run["head_sha"] == SHA and run["name"] in ("Windows desktop", "Release", "Android APK"):
            key = run["id"]
            if key not in runs or runs[key]["status"] != "completed":
                runs[key] = run
    summary = " | ".join(
        "%s:%s/%s" % (r["name"], r["status"], r["conclusion"]) for r in runs.values()
    )
    print("%.0fs: %s" % (time.time() - START, summary), flush=True)
    if runs and all(r["status"] == "completed" for r in runs.values()) and len(runs) >= 2:
        break
    time.sleep(25)

for r in runs.values():
    print("run", r["id"], r["name"], r["status"], r["conclusion"], r["html_url"], flush=True)
    for job in call(
        "https://api.github.com/repos/tsalisbury0/sector-scout/actions/runs/%d/jobs" % r["id"]
    )["jobs"]:
        print("  job", job["name"], "->", job["conclusion"], flush=True)

for attempt in range(10):
    time.sleep(10)
    try:
        release = call(
            "https://api.github.com/repos/tsalisbury0/sector-scout/releases/tags/v1.0.2-beta"
        )
        print("release page:", release["html_url"], "prerelease:", release["prerelease"], flush=True)
        for asset in release["assets"]:
            print("asset", asset["name"], asset["size"], flush=True)
        break
    except Exception as error:  # noqa: BLE001
        print("release read failed:", error, flush=True)
