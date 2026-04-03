#!/usr/bin/env python3
"""Send a hello message for each user in users.csv via the webhook (async, no LLM wait)."""

import asyncio
import csv
import hashlib
import hmac
import httpx
import json as json_mod
import time
import sys

BASE_URL = "http://34.69.64.144"
SECRET = "REDACTED_WEBHOOK_SECRET_v1"
CONCURRENCY = 50  # stay under per-shard rate limits (60/min * 10 shards = 600/min)
CSV_FILE = "users.csv"


def sign(body: bytes) -> str:
    return f"sha256={hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()}"


async def send_hello(client, sem, user):
    async with sem:
        payload = json_mod.dumps({
            "content": f"Hello! I am {user['name']}. Remember my name.",
            "user_id": user["id"],
            "wait_for_response": False,
        }).encode()
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
            return resp.status_code
        except Exception as e:
            return str(e)[:40]


async def main():
    with open(CSV_FILE) as f:
        users = list(csv.DictReader(f))

    print(f"Sending hello to {len(users)} users (concurrency={CONCURRENCY})")
    sem = asyncio.Semaphore(CONCURRENCY)

    limits = httpx.Limits(max_connections=CONCURRENCY, max_keepalive_connections=CONCURRENCY)
    async with httpx.AsyncClient(limits=limits) as client:
        start = time.time()
        batch_size = 500
        total_ok = 0
        total_rl = 0
        total_err = 0

        for batch_start in range(0, len(users), batch_size):
            batch = users[batch_start:batch_start + batch_size]
            batch_num = batch_start // batch_size + 1
            t = time.time()

            tasks = [send_hello(client, sem, u) for u in batch]
            results = await asyncio.gather(*tasks)

            ok = sum(1 for r in results if r == 200)
            rl = sum(1 for r in results if r == 429)
            err = len(results) - ok - rl
            total_ok += ok
            total_rl += rl
            total_err += err

            print(f"  Batch {batch_num}: {ok}/{len(batch)} OK, {rl} rate-limited, {err} errors ({time.time()-t:.1f}s)")

            # If we got rate-limited, pause before next batch
            if rl > 0:
                wait = 60 - (time.time() - t)
                if wait > 0:
                    print(f"  Rate-limited — waiting {wait:.0f}s for reset...")
                    await asyncio.sleep(wait)

        elapsed = time.time() - start

    print(f"\nDone in {elapsed:.1f}s")
    print(f"  OK: {total_ok}  Rate-limited: {total_rl}  Errors: {total_err}")
    print(f"  Throughput: {total_ok/elapsed:.0f} msgs/s")


if __name__ == "__main__":
    asyncio.run(main())
