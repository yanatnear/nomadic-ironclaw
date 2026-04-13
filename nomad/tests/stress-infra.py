#!/usr/bin/env python3
"""
IronClaw Infrastructure Stress Test

Tests the non-LLM parts: webhook ingestion, auth, user session creation,
DB writes, load balancing, and connection handling.
Uses wait_for_response=false to avoid LLM rate limits.
"""

import asyncio
import hashlib
import hmac
import httpx
import json as json_mod
import sys
import uuid
import time
import statistics
from datetime import datetime

import os

BASE_URL = sys.argv[1] if len(sys.argv) > 1 else "http://34.69.64.144"
SECRET = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("HTTP_WEBHOOK_SECRET")
if not SECRET:
    sys.exit(f"Usage: {sys.argv[0]} URL WEBHOOK_SECRET (or set HTTP_WEBHOOK_SECRET env var)")

# Waves: (num_requests, concurrency, description)
WAVES = [
    (50, 50, "warm-up: 50 unique users"),
    (200, 100, "200 unique users, 100 concurrent"),
    (500, 200, "500 unique users, 200 concurrent"),
    (1000, 500, "1000 unique users, 500 concurrent"),
    (1000, 1000, "1000 users, full blast"),
]


def sign(body: bytes) -> str:
    return f"sha256={hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()}"


async def send_async_message(client, user_id, msg):
    """Send message with wait_for_response=false — tests infra only."""
    payload = json_mod.dumps({
        "content": msg,
        "user_id": user_id,
        "wait_for_response": False,
    }).encode()
    start = time.time()
    try:
        resp = await client.post(
            f"{BASE_URL}/webhook",
            content=payload,
            headers={
                "Content-Type": "application/json",
                "X-Hub-Signature-256": sign(payload),
            },
            timeout=30.0,
        )
        dur = time.time() - start
        if resp.status_code == 200:
            return {"ok": True, "duration": dur, "status": 200}
        elif resp.status_code == 429:
            return {"ok": False, "duration": dur, "status": 429, "error": "rate_limited"}
        else:
            return {"ok": False, "duration": dur, "status": resp.status_code, "error": resp.text[:100]}
    except httpx.TimeoutException:
        return {"ok": False, "duration": time.time() - start, "status": 0, "error": "timeout"}
    except httpx.ConnectError as e:
        return {"ok": False, "duration": time.time() - start, "status": 0, "error": f"connect: {e}"}
    except Exception as e:
        return {"ok": False, "duration": time.time() - start, "status": 0, "error": str(e)[:100]}


async def health_check(client):
    """Simple health check — tests basic routing."""
    start = time.time()
    try:
        resp = await client.get(f"{BASE_URL}/health", timeout=10.0)
        dur = time.time() - start
        return {"ok": resp.status_code == 200, "duration": dur, "status": resp.status_code}
    except Exception as e:
        return {"ok": False, "duration": time.time() - start, "status": 0, "error": str(e)[:100]}


async def run_wave(wave_num, num_requests, concurrency, desc):
    print(f"\n{'='*60}")
    print(f"Wave {wave_num}: {desc}")
    print(f"{'='*60}")

    limits = httpx.Limits(max_connections=concurrency, max_keepalive_connections=concurrency)
    async with httpx.AsyncClient(limits=limits) as client:
        sem = asyncio.Semaphore(concurrency)

        async def bounded_send(i):
            uid = f"stress-w{wave_num}-u{i}-{uuid.uuid4().hex[:4]}"
            async with sem:
                return await send_async_message(client, uid, f"Message {i} from stress test")

        wave_start = time.time()
        tasks = [bounded_send(i) for i in range(num_requests)]
        results = await asyncio.gather(*tasks)
        wall_time = time.time() - wave_start

    successes = [r for r in results if r["ok"]]
    failures = [r for r in results if not r["ok"]]
    durations = [r["duration"] for r in results]
    ok_durations = [r["duration"] for r in successes]

    print(f"\nResults:")
    print(f"  Total:        {num_requests}")
    print(f"  Success:      {len(successes)} ({len(successes)/num_requests*100:.0f}%)")
    print(f"  Failed:       {len(failures)}")
    print(f"  Wall time:    {wall_time:.2f}s")
    print(f"  Throughput:   {num_requests/wall_time:.1f} req/s")
    if ok_durations:
        print(f"  Latency (ok): min={min(ok_durations)*1000:.0f}ms  med={statistics.median(ok_durations)*1000:.0f}ms  p95={sorted(ok_durations)[int(len(ok_durations)*0.95)]*1000:.0f}ms  max={max(ok_durations)*1000:.0f}ms")
    if failures:
        error_types = {}
        for r in failures:
            e = r.get("error", f"http_{r['status']}")[:60]
            error_types[e] = error_types.get(e, 0) + 1
        print(f"  Errors:")
        for e, cnt in sorted(error_types.items(), key=lambda x: -x[1])[:5]:
            print(f"    [{cnt}x] {e}")

    return {
        "wave": wave_num,
        "requests": num_requests,
        "concurrency": concurrency,
        "success": len(successes),
        "failed": len(failures),
        "wall_time": wall_time,
        "throughput": num_requests / wall_time,
        "median_ms": statistics.median(ok_durations) * 1000 if ok_durations else 0,
        "p95_ms": sorted(ok_durations)[int(len(ok_durations) * 0.95)] * 1000 if ok_durations else 0,
    }


async def main():
    print(f"IronClaw Infrastructure Stress Test")
    print(f"Target: {BASE_URL}")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Mode: async (wait_for_response=false) — exercises auth, routing, DB, sessions")

    async with httpx.AsyncClient() as client:
        h = await health_check(client)
        if not h["ok"]:
            print(f"Health check failed")
            return
        print(f"Health: OK ({h['duration']*1000:.0f}ms)")

    summary = []
    for i, (reqs, conc, desc) in enumerate(WAVES, 1):
        result = await run_wave(i, reqs, conc, desc)
        summary.append(result)
        if i < len(WAVES):
            await asyncio.sleep(2)

    print(f"\n{'='*60}")
    print(f"SUMMARY")
    print(f"{'='*60}")
    print(f"{'Wave':>5} {'Reqs':>6} {'Conc':>5} {'OK':>6} {'Fail':>5} {'Thru':>8} {'Med':>7} {'P95':>7}")
    print(f"{' ':>5} {' ':>6} {' ':>5} {' ':>6} {' ':>5} {'(r/s)':>8} {'(ms)':>7} {'(ms)':>7}")
    print(f"{'-'*56}")
    for s in summary:
        print(f"{s['wave']:>5} {s['requests']:>6} {s['concurrency']:>5} {s['success']:>6} {s['failed']:>5} {s['throughput']:>8.1f} {s['median_ms']:>7.0f} {s['p95_ms']:>7.0f}")

    total_reqs = sum(s["requests"] for s in summary)
    total_ok = sum(s["success"] for s in summary)
    print(f"\nTotal: {total_ok}/{total_reqs} OK ({total_ok/total_reqs*100:.1f}%)")
    print(f"Finished: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(0)
