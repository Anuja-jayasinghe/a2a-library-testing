#!/usr/bin/env python3
"""A TCP proxy that cuts the FIRST streaming (POST .../message:stream) connection after N seconds,
then behaves normally. It exists to make an SSE stream drop mid-flight, so a client's opt-in
reconnection can be tested against a real server.

Usage: flaky_proxy.py <listen_port> <upstream_port> [cut_after_seconds=3]
"""
import asyncio, sys

LISTEN, UPSTREAM = int(sys.argv[1]), int(sys.argv[2])
CUT_AFTER = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
state = {"cut": False}


async def pipe(r, w, on_client_data=None):
    try:
        while data := await r.read(65536):
            if on_client_data:
                on_client_data(data)
            w.write(data)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass


async def handle(cr, cw):
    ur, uw = await asyncio.open_connection("localhost", UPSTREAM)
    tasks = []

    async def cut_later():
        await asyncio.sleep(CUT_AFTER)
        print(f"proxy: cutting the streaming connection after {CUT_AFTER}s", flush=True)
        for w in (cw, uw):
            w.close()
        for t in tasks:
            t.cancel()

    def inspect(data: bytes):
        # A client may reuse one keep-alive connection for many requests (a card GET, then the
        # stream POST), so every chunk is inspected, not just the first on the connection.
        if not state["cut"] and b"POST /message:stream" in data:
            state["cut"] = True
            asyncio.get_running_loop().create_task(cut_later())

    tasks += [asyncio.create_task(pipe(cr, uw, inspect)), asyncio.create_task(pipe(ur, cw))]
    await asyncio.gather(*tasks, return_exceptions=True)


async def main():
    server = await asyncio.start_server(handle, "localhost", LISTEN)
    async with server:
        await server.serve_forever()

asyncio.run(main())
