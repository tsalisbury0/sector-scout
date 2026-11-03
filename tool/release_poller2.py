import json
import os
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
START = time.time()


def call(url):
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + os.environ["GHTOK"])
    return json.load(urllib.request.urlopen(req))


def find_run():
    runs = call(
        "https://api.github.com/repos/tsalisbury0/sector-scout/actions/runs?name=Release&per_page=10"
    )["workflow_runs"]
    for run in runs:
        if run["head_branch"] == "v1.0.1":
            return run
    return None


run = None
while time.time() - START < 25 * 60:
    run = find_run()
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

print("run", run["id"], run["status"], run["conclusion"], run["html_url"], flush=True)
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
        print("body:", (release.get("body") or "")[:200].replace("\n", " | "), flush=True)
        for asset in release["assets"]:
            print("asset", asset["name"], asset["size"], flush=True)
        break
    except Exception as error:  # noqa: BLE001
        print("release read failed:", error, flush=True)
