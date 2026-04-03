#!/usr/bin/env python3
"""Quick check: send a few requests and print full responses."""

import asyncio
import hashlib
import hmac
import httpx
import json as json_mod
import time

BASE_URL = "http://34.69.64.144"
SECRET = "REDACTED_WEBHOOK_SECRET_v1"


def sign(body: bytes) -> str:
    return f"sha256={hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()}"


async def send(client, user_id, msg):
    payload = json_mod.dumps({"content": msg, "user_id": user_id, "wait_for_response": True}).encode()
    start = time.time()
    resp = await client.post(
        f"{BASE_URL}/webhook",
        content=payload,
        headers={"Content-Type": "application/json", "X-Hub-Signature-256": sign(payload)},
        timeout=120.0,
    )
    dur = time.time() - start
    data = resp.json()
    reply = data.get("response", "")
    print(f"[{dur:.1f}s] {user_id}: status={data.get('status')} reply={reply[:120]}")
    return reply


async def main():
    async with httpx.AsyncClient() as client:
        # Send 5 concurrent requests with different users
        tasks = []
        for i in range(5):
            tasks.append(send(client, f"verify-{i}", f"What is {i+1} times {i+2}? Just the number."))
        await asyncio.gather(*tasks)


asyncio.run(main())
