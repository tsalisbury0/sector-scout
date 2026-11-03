import asyncio
import json
import os
import queue
import struct
import subprocess
import sys
import threading
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from bleak import BleakClient  # noqa: E402

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
            frames.put(json.loads(body.decode("utf-8", "replace")))
        except Exception:  # noqa: BLE001
            frames.put({"_raw": body.decode("utf-8", "replace")})


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


def frame_of(value):
    low = [b & 0xFF for b in value]
    return (len(low), low[0], low[1])


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
a = result("read", device=handle, service=win_uuid(SERVICE), characteristic=win_uuid(DATA))
b = result("read", device=handle, service=win_uuid(SERVICE), characteristic=win_uuid(DATA))
print("win_ble read 1 (len, index, total):", frame_of(a) if isinstance(a, list) else a)
print("win_ble read 2 (len, index, total):", frame_of(b) if isinstance(b, list) else b)
print("identical:", a == b)


async def ask_phone():
    async with BleakClient(address, timeout=25.0) as client:
        first = bytes(await asyncio.wait_for(client.read_gatt_char(DATA), timeout=8))
        second = bytes(await asyncio.wait_for(client.read_gatt_char(DATA), timeout=8))
        return (len(first), first[0], first[1]), (len(second), second[0], second[1])


print("=== now asking the phone directly, uncached, on the same link ===")
try:
    one, two = asyncio.run(ask_phone())
except Exception as error:  # noqa: BLE001
    print("bleak failed:", error)
    one = two = None
print("phone read 1 (len, index, total):", one)
print("phone read 2 (len, index, total):", two)
print()
print("Interpretation:")
print("  phone read 1 index 0 -> the bridge's two reads never reached the phone (cached).")
print("  phone read 1 index 2 -> the bridge did read, and the phone rewound between them.")

result("disconnect", device=handle)
process.terminate()
