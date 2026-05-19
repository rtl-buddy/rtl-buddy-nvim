"""Mock 'view' client used by the live integration test.

Connects to a running rtl-buddy-hub, registers as `origin=view`, prints the
first `source_focused` broadcast it sees as a single JSON line, then exits.

The orchestrating shell script (run_live_hub.sh) parses that line to assert
the plugin sent the right envelope on the wire.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import uuid


async def main(host: str, port: int, timeout: float) -> int:
    reader, writer = await asyncio.open_connection(host, port)
    hello = {
        "v": 1,
        "id": str(uuid.uuid4()),
        "origin": "view",
        "kind": "request",
        "type": "hello",
        "payload": {"client": "view", "version": "0.0.0", "capabilities": []},
    }
    writer.write((json.dumps(hello) + "\n").encode())
    await writer.drain()

    welcome_line = await asyncio.wait_for(reader.readline(), timeout=timeout)
    welcome = json.loads(welcome_line)
    if welcome.get("type") != "welcome":
        print(f"ERROR: expected welcome, got {welcome}", file=sys.stderr)
        return 2

    print(f"WELCOME {json.dumps(welcome.get('payload', {}))}", flush=True)

    deadline = asyncio.get_event_loop().time() + timeout
    while True:
        remaining = max(deadline - asyncio.get_event_loop().time(), 0.1)
        line = await asyncio.wait_for(reader.readline(), timeout=remaining)
        if not line:
            print("ERROR: hub closed connection before source_focused", file=sys.stderr)
            return 3
        env = json.loads(line)
        if env.get("type") == "source_focused":
            print(f"RECEIVED {json.dumps(env)}", flush=True)
            writer.close()
            await writer.wait_closed()
            return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--timeout", type=float, default=10.0)
    args = p.parse_args()
    try:
        sys.exit(asyncio.run(main(args.host, args.port, args.timeout)))
    except asyncio.TimeoutError:
        print("ERROR: timed out waiting for source_focused", file=sys.stderr)
        sys.exit(4)
