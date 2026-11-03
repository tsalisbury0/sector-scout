import json
import os
import queue
import struct
import subprocess
import sys
import threading
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = r"C:\Users\tsali\Downloads\sector-scout-windows"
SERVER = os.path.join(
    ROOT, "data", "flutter_assets", "packages", "win_ble", "assets", "BLEServer.exe"
)
CONFIG = os.path.join(os.environ["APPDATA"], "Sector Scout", "desktop.json")

SERVICE = "d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d00"
DATA = "d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d01"
RESET = "d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d02"


def win_uuid(uuid):
    return "{" + uuid + "}"


address = None
try:
    with open(CONFIG, encoding="utf-8") as handle:
        for phone in json.load(handle).get("phones", []):
            if isinstance(phone, str) and phone.startswith("ble:"):
                address = phone[4:]
                break
except Exception as error:  # noqa: BLE001
    print("config unreadable:", error)

print("server", os.path.getsize(SERVER), "bytes")
print("phone", address)
if not address:
    raise SystemExit("no Bluetooth phone saved")

process = subprocess.Popen(
    [SERVER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)

frames = queue.Queue()


def read_frames():
    stream = process.stdout
    while True:
        head = stream.read(4)
        if len(head) < 4:
            break
        (size,) = struct.unpack("<I", head)
        body = stream.read(size)
        if len(body) < size:
            break
        try:
            frames.put(json.loads(body.decode("utf-8", "replace")))
        except Exception:  # noqa: BLE001
            frames.put({"_raw": body.decode("utf-8", "replace")})


def read_errors():
    for line in process.stderr:
        text = line.decode("utf-8", "replace").rstrip()
        if text:
            print("stderr:", text[:300])


threading.Thread(target=read_frames, daemon=True).start()
threading.Thread(target=read_errors, daemon=True).start()

next_id = 0


def call(cmd, timeout=15.0, **args):
    global next_id
    next_id += 1
    payload = {"cmd": cmd, "_id": next_id}
    payload.update(args)
    body = json.dumps(payload).encode()
    process.stdin.write(struct.pack("<I", len(body)) + body)
    process.stdin.flush()

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            message = frames.get(timeout=0.3)
        except queue.Empty:
            if process.poll() is not None:
                print("server exited", process.returncode)
                return None
            continue
        if message.get("_type") == "response" and message.get("_id") == next_id:
            return message
        if message.get("_type") not in (None, "response"):
            print("event:", json.dumps(message)[:160])
    print(cmd, "-> no answer")
    return None


def result(cmd, **args):
    message = call(cmd, **args)
    if message is None:
        return None
    if message.get("error"):
        print(cmd, "error:", message["error"])
        return None
    return message.get("result")


print("version:", result("version"))
print("radio:", result("radioState"))

handle = result("connect", address=address.replace(":", ""))
print("handle:", handle)
if not handle:
    raise SystemExit("connect failed")

print("max mtu:", result("getMaxMtuSize", device=handle))
services = result("services", device=handle, forceRefresh=True)
print("services:", services)
if not services:
    raise SystemExit("no services")

wrote = result(
    "write",
    device=handle,
    service=win_uuid(SERVICE),
    characteristic=win_uuid(RESET),
    value=[0],
    writeWithResponse=True,
)
print("reset write:", wrote)

print("=== twelve reads straight after the rewind ===")
previous = None
for index in range(12):
    value = result(
        "read",
        device=handle,
        service=win_uuid(SERVICE),
        characteristic=win_uuid(DATA),
    )
    if not isinstance(value, list):
        print("read", index, "->", value)
        continue
    # The bridge may hand bytes back signed.
    low = [b & 0xFF for b in value]
    frame = (low[0], low[1]) if len(low) > 1 else None
    print(
        "read", index,
        "len", len(low),
        "index/total", frame,
        "same as previous", value == previous,
    )
    previous = value

print("=== reads three seconds apart ===")
for index in range(4):
    time.sleep(3)
    value = result(
        "read",
        device=handle,
        service=win_uuid(SERVICE),
        characteristic=win_uuid(DATA),
    )
    if not isinstance(value, list):
        print("read", index, "->", value)
        continue
    low = [b & 0xFF for b in value]
    print(
        "read", index,
        "len", len(low),
        "index/total", (low[0], low[1]) if len(low) > 1 else None,
    )

call("disconnect", device=handle)
process.terminate()
