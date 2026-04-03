#!/usr/bin/env python3
"""
IronClaw Stress Test

Ramps up concurrent users in waves to find the breaking point.
Measures latency, throughput, error rates, and resource pressure.
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

BASE_URL = sys.argv[1] if len(sys.argv) > 1 else "http://34.69.64.144"
WEBHOOK_SECRET = sys.argv[2] if len(sys.argv) > 2 else "REDACTED_WEBHOOK_SECRET_v1"

# Waves: (num_users, concurrency)
WAVES = [
    (10, 10),      # warm-up
    (25, 25),      # light load
    (50, 50),      # moderate
    (100, 50),     # heavy
    (200, 100),    # stress
]

MESSAGES = [
    "What is 2+2?",
    "Say hello in French.",
    "Name a color.",
    "What day comes after Monday?",
    "Is the sky blue? One word answer.",
]


def sign_body(secret: str, body: bytes) -> str:
    mac = hmac.new(secret.encode(), body, hashlib.sha256)
    return f"sha256={mac.hexdigest()}"


async def send_message(client, user_id, message):
    start = time.time()
    try:
        payload = json_mod.dumps({
            "content": message,
            "user_id": user_id,
            "wait_for_response": True,
        }).encode()
        sig = sign_body(WEBHOOK_SECRET, payload)
        resp = await client.post(
            f"{BASE_URL}/webhook",
            content=payload,
            headers={
                "Content-Type": "application/json",
                "X-Hub-Signature-256": sig,
            },
            timeout=120.0,
        )
        duration = time.time() - start
        if resp.status_code == 200:
            data = resp.json()
            reply = data.get("response", "")
            is_error = reply.startswith("Error:")
            return {"ok": not is_error, "duration": duration, "status": resp.status_code, "error": reply if is_error else None}
        elif resp.status_code == 429:
            return {"ok": False, "duration": duration, "status": 429, "error": "rate_limited"}
        else:
            return {"ok": False, "duration": duration, "status": resp.status_code, "error": resp.text[:100]}
    except httpx.TimeoutException:
        return {"ok": False, "duration": time.time() - start, "status": 0, "error": "timeout"}
    except Exception as e:
        return {"ok": False, "duration": time.time() - start, "status": 0, "error": str(e)[:100]}


async def run_wave(wave_num, num_users, concurrency):
    print(f"\n{'='*60}")
    print(f"Wave {wave_num}: {num_users} users, concurrency={concurrency}")
    print(f"{'='*60}")

    async with httpx.AsyncClient() as client:
        sem = asyncio.Semaphore(concurrency)
        user_ids = [f"stress-w{wave_num}-u{i}-{uuid.uuid4().hex[:4]}" for i in range(num_users)]

        async def bounded_send(uid, idx):
            async with sem:
                msg = MESSAGES[idx % len(MESSAGES)]
                return await send_message(client, uid, msg)

        wave_start = time.time()
        tasks = [bounded_send(uid, i) for i, uid in enumerate(user_ids)]
        results = await asyncio.gather(*tasks)
        wall_time = time.time() - wave_start

    # Analyze
    successes = [r for r in results if r["ok"]]
    failures = [r for r in results if not r["ok"]]
    durations = [r["duration"] for r in results]
    ok_durations = [r["duration"] for r in successes]

    rate_limited = sum(1 for r in failures if r.get("error") == "rate_limited")
    timeouts = sum(1 for r in failures if r.get("error") == "timeout")
    llm_errors = sum(1 for r in failures if r.get("error") and r["error"].startswith("Error:"))
    other_errors = len(failures) - rate_limited - timeouts - llm_errors

    print(f"\nResults:")
    print(f"  Total:        {num_users}")
    print(f"  Success:      {len(successes)} ({len(successes)/num_users*100:.0f}%)")
    print(f"  Failed:       {len(failures)} (rate_limited={rate_limited}, timeout={timeouts}, llm_err={llm_errors}, other={other_errors})")
    print(f"  Wall time:    {wall_time:.1f}s")
    print(f"  Throughput:   {num_users/wall_time:.1f} req/s")
    if durations:
        print(f"  Latency (all):  min={min(durations):.1f}s  median={statistics.median(durations):.1f}s  p95={sorted(durations)[int(len(durations)*0.95)]:.1f}s  max={max(durations):.1f}s")
    if ok_durations:
        print(f"  Latency (ok):   min={min(ok_durations):.1f}s  median={statistics.median(ok_durations):.1f}s  p95={sorted(ok_durations)[int(len(ok_durations)*0.95)]:.1f}s  max={max(ok_durations):.1f}s")

    # Show sample errors
    error_types = {}
    for r in failures:
        e = r.get("error", "unknown")[:80]
        error_types[e] = error_types.get(e, 0) + 1
    if error_types:
        print(f"  Error breakdown:")
        for e, count in sorted(error_types.items(), key=lambda x: -x[1])[:5]:
            print(f"    [{count}x] {e}")

    return {
        "wave": wave_num,
        "users": num_users,
        "concurrency": concurrency,
        "success": len(successes),
        "failed": len(failures),
        "wall_time": wall_time,
        "throughput": num_users / wall_time,
        "median_latency": statistics.median(durations) if durations else 0,
        "p95_latency": sorted(durations)[int(len(durations) * 0.95)] if durations else 0,
    }


async def main():
    print(f"IronClaw Stress Test")
    print(f"Target: {BASE_URL}")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    # Health check
    async with httpx.AsyncClient() as client:
        try:
            h = await client.get(f"{BASE_URL}/health", timeout=5)
            if h.status_code != 200:
                print(f"Health check failed: {h.status_code}")
                return
            print(f"Health: OK")
        except Exception as e:
            print(f"Cannot connect: {e}")
            return

    summary = []
    for i, (users, conc) in enumerate(WAVES, 1):
        result = await run_wave(i, users, conc)
        summary.append(result)
        # Brief pause between waves
        if i < len(WAVES):
            print(f"\n  [pause 3s before next wave]")
            await asyncio.sleep(3)

    # Final summary
    print(f"\n{'='*60}")
    print(f"SUMMARY")
    print(f"{'='*60}")
    print(f"{'Wave':>5} {'Users':>6} {'Conc':>5} {'OK':>5} {'Fail':>5} {'Thru(r/s)':>10} {'Med(s)':>7} {'P95(s)':>7}")
    print(f"{'-'*56}")
    for s in summary:
        print(f"{s['wave']:>5} {s['users']:>6} {s['concurrency']:>5} {s['success']:>5} {s['failed']:>5} {s['throughput']:>10.1f} {s['median_latency']:>7.1f} {s['p95_latency']:>7.1f}")
    print(f"\nFinished: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(0)
