import json
import os
import queue
import re
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
with open(CONFIG, encoding="utf-8") as handle:
    for phone in json.load(handle).get("phones", []):
        if isinstance(phone, str) and phone.startswith("ble:"):
            address = phone[4:]
            break
print("phone", address)

process = subprocess.Popen(
    [SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
)
frames = queue.Queue()


def read_frames():
    while True:
        head = process.stdout.read(4)
        if len(head) < 4:
            return
        (size,) = struct.unpack("<I", head)
        body = process.stdout.read(size)
        if len(body) < size:
            return
        try:
            frames.put(json.loads(body.decode("utf-8", "replace").strip()))
        except Exception:  # noqa: BLE001
            pass


threading.Thread(target=read_frames, daemon=True).start()
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
            continue
        if message.get("_type") == "response" and message.get("_id") == next_id:
            return message
    return None


def result(cmd, **args):
    message = call(cmd, **args)
    if not message:
        return None
    if message.get("error"):
        print(cmd, "error:", message["error"])
        return None
    return message.get("result")


def stamp(value):
    if not isinstance(value, list):
        return value
    low = bytes([b & 0xFF for b in value])
    found = re.search(rb'"timestamp":(\d+)', low)
    return {
        "len": len(low),
        "index": low[0],
        "total": low[1],
        "timestamp": found.group(1).decode() if found else "?",
        "crc": sum(low),
    }


handle = result("connect", address=address.replace(":", ""))
print("handle:", handle)
result(
    "write",
    device=handle,
    service=win_uuid(SERVICE),
    characteristic=win_uuid(RESET),
    value=[0],
    writeWithResponse=True,
)

first = result(
    "read", device=handle, service=win_uuid(SERVICE), characteristic=win_uuid(DATA)
)
print("read now    :", stamp(first))
time.sleep(5)
second = result(
    "read", device=handle, service=win_uuid(SERVICE), characteristic=win_uuid(DATA)
)
print("read +5s    :", stamp(second))
print("identical across 5s:", first == second)

print("=== after a reconnect ===")
result("disconnect", device=handle)
time.sleep(1)
handle = result("connect", address=address.replace(":", ""))
after = result(
    "read", device=handle, service=win_uuid(SERVICE), characteristic=win_uuid(DATA)
)
print("read fresh  :", stamp(after))
print()
print("timestamps differ over 5s -> the reads are real.")
print("timestamps identical over 5s -> the bridge serves a cached value.")

result("disconnect", device=handle)
process.terminate()
