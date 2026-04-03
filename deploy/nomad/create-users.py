#!/usr/bin/env python3
"""Create 1000 users via the admin API and save tokens to a CSV."""

import asyncio
import csv
import httpx
import sys
import time

BASE_URL = sys.argv[1] if len(sys.argv) > 1 else "http://34.69.64.144:9000"
ADMIN_TOKEN = "REDACTED_ADMIN_TOKEN_v1"
NUM_USERS = 1000
CONCURRENCY = 20
OUTPUT_FILE = "users.csv"


async def create_user(client, sem, i):
    async with sem:
        try:
            resp = await client.post(
                f"{BASE_URL}/api/admin/users",
                json={"display_name": f"Agent-{i:04d}", "role": "member"},
                headers={"Authorization": f"Bearer {ADMIN_TOKEN}"},
                timeout=30.0,
            )
            if resp.status_code == 200:
                data = resp.json()
                return {
                    "id": data["id"],
                    "name": data["display_name"],
                    "token": data["token"],
                    "url": f"{BASE_URL}/?token={data['token']}",
                }
            else:
                print(f"  User {i}: HTTP {resp.status_code} — {resp.text[:100]}")
                return None
        except Exception as e:
            print(f"  User {i}: {e}")
            return None


async def main():
    print(f"Creating {NUM_USERS} users on {BASE_URL}")
    sem = asyncio.Semaphore(CONCURRENCY)

    async with httpx.AsyncClient() as client:
        start = time.time()
        tasks = [create_user(client, sem, i) for i in range(NUM_USERS)]
        results = await asyncio.gather(*tasks)
        elapsed = time.time() - start

    users = [r for r in results if r]
    failed = NUM_USERS - len(users)

    # Save to CSV
    with open(OUTPUT_FILE, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["id", "name", "token", "url"])
        writer.writeheader()
        writer.writerows(users)

    print(f"\nCreated {len(users)}/{NUM_USERS} users in {elapsed:.1f}s ({len(users)/elapsed:.0f} users/s)")
    if failed:
        print(f"Failed: {failed}")
    print(f"Saved to {OUTPUT_FILE}")


if __name__ == "__main__":
    asyncio.run(main())
