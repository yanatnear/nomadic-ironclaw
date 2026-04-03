#!/usr/bin/env python3
"""Send hello to all 1000 users, retrying rate-limited ones with backoff."""

import asyncio
import csv
import hashlib
import hmac
import httpx
import json as json_mod
import time

BASE_URL = "http://34.69.64.144"
SECRET = "REDACTED_WEBHOOK_SECRET_v1"
CONCURRENCY = 30  # conservative to avoid rate limits
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
            return user["id"], resp.status_code
        except Exception as e:
            return user["id"], 0


async def main():
    with open(CSV_FILE) as f:
        users = list(csv.DictReader(f))

    remaining = users[:]
    total_ok = 0
    attempt = 0
    start = time.time()

    limits = httpx.Limits(max_connections=CONCURRENCY, max_keepalive_connections=CONCURRENCY)
    async with httpx.AsyncClient(limits=limits) as client:
        sem = asyncio.Semaphore(CONCURRENCY)

        while remaining:
            attempt += 1
            print(f"\nAttempt {attempt}: sending to {len(remaining)} users...")

            # Send in small batches to stay under rate limits
            batch_size = min(len(remaining), 500)
            batch = remaining[:batch_size]

            tasks = [send_hello(client, sem, u) for u in batch]
            results = await asyncio.gather(*tasks)

            ok_ids = set()
            rl_count = 0
            for uid, status in results:
                if status == 200:
                    ok_ids.add(uid)
                elif status == 429:
                    rl_count += 1

            total_ok += len(ok_ids)
            remaining = [u for u in remaining if u["id"] not in ok_ids]

            print(f"  OK: {len(ok_ids)}, rate-limited: {rl_count}, remaining: {len(remaining)}")
            print(f"  Total delivered: {total_ok}/1000")

            if remaining and rl_count > 0:
                print(f"  Waiting 62s for rate limit reset...")
                await asyncio.sleep(62)

    elapsed = time.time() - start
    print(f"\nDone in {elapsed:.0f}s — {total_ok}/1000 delivered")


if __name__ == "__main__":
    asyncio.run(main())
