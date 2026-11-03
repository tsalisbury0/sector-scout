import asyncio
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from bleak import BleakClient, BleakScanner  # noqa: E402

SERVICE = "d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d00"
DATA = "d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d01"
RESET = "d3a4e1b0-6c2f-4b8a-9f10-5e7c3a2b1d02"


async def main():
    found = await BleakScanner.discover(timeout=8.0, return_adv=True)
    target = None
    for address, (device, adv) in found.items():
        uuids = [str(u).lower() for u in (adv.service_uuids or [])]
        print("seen", address, repr(device.name), adv.rssi, uuids)
        if SERVICE in uuids and target is None:
            target = device
    if target is None:
        print("NO SHARE FOUND")
        return
    print("using", target.address, repr(target.name))

    async with BleakClient(target, timeout=25.0) as client:
        print("connected", client.is_connected)
        print("has data characteristic", client.services.get_characteristic(DATA) is not None)
        try:
            await client.write_gatt_char(RESET, b"\x00", response=True)
            print("reset written")
        except Exception as error:  # noqa: BLE001
            print("reset failed", error)

        frames = []
        for index in range(8):
            try:
                raw = await asyncio.wait_for(client.read_gatt_char(DATA), timeout=8)
            except Exception as error:  # noqa: BLE001
                print("read", index, "failed", error)
                break
            data = bytes(raw)
            frames.append(data)
            head = (data[0], data[1]) if len(data) > 1 else None
            print(
                "frame",
                index,
                "len",
                len(data),
                "bytes0/1",
                head,
                "payload starts",
                data[2:44],
            )

        chunks = {}
        total = 0
        for data in frames:
            if len(data) < 3:
                continue
            total = data[1]
            chunks[data[0]] = data[2:]
        joined = b"".join(chunks.get(i, b"") for i in range(total))
        print("total claimed", total, "chunks held", len(chunks), "joined", len(joined))
        print("joined starts", joined[:120])
        print("joined ends", joined[-60:])


asyncio.run(main())
