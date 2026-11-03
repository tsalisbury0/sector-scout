import json
import os
import sys
import time
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
RUN = 41576155872
START = time.time()


def call(url):
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + os.environ["GHTOK"])
    return json.load(urllib.request.urlopen(req))


while True:
    run = call("https://api.github.com/repos/tsalisbury0/sector-scout/actions/runs/%d" % RUN)
    print("poll %.0fs: %s %s" % (time.time() - START, run["status"], run["conclusion"]), flush=True)
    if run["status"] == "completed":
        break
    time.sleep(25)

print("run", run["id"], run["status"], run["conclusion"], run["html_url"], flush=True)
for job in call(
    "https://api.github.com/repos/tsalisbury0/sector-scout/actions/runs/%d/jobs" % RUN
)["jobs"]:
    print("job", job["name"], "->", job["conclusion"], flush=True)

# The release publication can lag the run by a moment.
for attempt in range(6):
    time.sleep(10)
    try:
        release = call(
            "https://api.github.com/repos/tsalisbury0/sector-scout/releases/tags/v1.0.0"
        )
        print("release body:", (release.get("body") or "")[:160].replace("\n", " | "), flush=True)
        for asset in release["assets"]:
            print("asset", asset["name"], asset["size"], flush=True)
        break
    except Exception as error:  # noqa: BLE001
        print("release read failed:", error, flush=True)
