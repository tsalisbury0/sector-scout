import json
import subprocess
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
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


def newest_v101_run():
    runs = call(
        "https://api.github.com/repos/tsalisbury0/sector-scout/actions/runs?name=Release&per_page=10"
    )["workflow_runs"]
    runs = [r for r in runs if r["head_branch"] == "v1.0.1"]
    return runs[0] if runs else None


run = None
while time.time() - START < 30 * 60:
    run = newest_v101_run()
    if run is None:
        print("%.0fs: waiting for the v1.0.1 run to appear" % (time.time() - START), flush=True)
    else:
        print(
            "%.0fs: run %d %s %s" % (time.time() - START, run["id"], run["status"], run["conclusion"]),
            flush=True,
        )
        if run["status"] == "completed":
            break
    time.sleep(25)

if run is None:
    print("no v1.0.1 run appeared", flush=True)
    raise SystemExit(1)

print("run", run["id"], "sha", run["head_sha"][:7], run["status"], run["conclusion"], flush=True)
for job in call(
    "https://api.github.com/repos/tsalisbury0/sector-scout/actions/runs/%d/jobs" % run["id"]
)["jobs"]:
    print("job", job["name"], "->", job["conclusion"], flush=True)

for attempt in range(8):
    time.sleep(10)
    try:
        release = call(
            "https://api.github.com/repos/tsalisbury0/sector-scout/releases/tags/v1.0.1"
        )
        for asset in release["assets"]:
            print(
                "asset", asset["name"], asset["size"],
                "%s %d" % (asset["updated_at"], asset["download_count"]),
                flush=True,
            )
        break
    except Exception as error:  # noqa: BLE001
        print("release read failed:", error, flush=True)
