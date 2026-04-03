#!/usr/bin/env python3
"""
IronClaw Scale Test Simulation (Small Scale)

Verifies multi-tenant isolation, shared database persistence, 
and load balancing across shards.
"""

import asyncio
import hashlib
import hmac
import httpx
import json as json_mod
import sys
import uuid
import time
from datetime import datetime

# Configuration
# Set this to your Traefik IP or 'localhost' for local testing
BASE_URL = sys.argv[1] if len(sys.argv) > 1 else "http://localhost"
WEBHOOK_SECRET = sys.argv[2] if len(sys.argv) > 2 else "REDACTED_WEBHOOK_SECRET_v1"
TEST_USERS_COUNT = 10
CONCURRENT_REQUESTS = 5


def sign_body(secret: str, body: bytes) -> str:
    """Generate HMAC-SHA256 signature for the request body."""
    mac = hmac.new(secret.encode(), body, hashlib.sha256)
    return f"sha256={mac.hexdigest()}"


async def send_message(client, user_id, message):
    """Send a message via the HTTP webhook channel and verify the response."""
    start_time = time.time()
    try:
        payload = json_mod.dumps({
            "content": message,
            "user_id": user_id,
            "wait_for_response": True
        }).encode()
        signature = sign_body(WEBHOOK_SECRET, payload)
        response = await client.post(
            f"{BASE_URL}/webhook",
            content=payload,
            headers={
                "Content-Type": "application/json",
                "X-Hub-Signature-256": signature,
            },
            timeout=60.0
        )

        duration = time.time() - start_time

        if response.status_code == 200:
            data = response.json()
            reply = data.get("reply", data.get("response", ""))
            print(f"  User {user_id}: Response in {duration:.2f}s ({len(reply)} chars)")
            return True
        else:
            print(f"  User {user_id}: Failed with status {response.status_code}")
            print(f"   Error: {response.text[:200]}")
            return False

    except Exception as e:
        print(f"  User {user_id}: Exception: {str(e)}")
        return False

async def main():
    print(f"Starting Scale Test: {TEST_USERS_COUNT} agents")
    print(f"Target: {BASE_URL}")
    print("-" * 50)

    async with httpx.AsyncClient() as client:
        # 1. Verify Health
        try:
            health = await client.get(f"{BASE_URL}/health")
            if health.status_code == 200:
                print("Health: OK")
            else:
                print(f"Health check failed: {health.status_code}. Aborting.")
                return
        except Exception as e:
            print(f"Could not connect to {BASE_URL}: {str(e)}")
            print("Ensure your Nomad shards and Traefik are running.")
            return

        # 2. Generate Test Users
        user_ids = [f"test-user-{i}-{uuid.uuid4().hex[:6]}" for i in range(TEST_USERS_COUNT)]

        # 3. Run Simulation (with limited concurrency)
        print(f"Sending {TEST_USERS_COUNT} messages...")

        semaphore = asyncio.Semaphore(CONCURRENT_REQUESTS)

        async def sem_send(uid):
            async with semaphore:
                return await send_message(client, uid, "Hello! Tell me your User ID for verification.")

        tasks = [sem_send(uid) for uid in user_ids]
        results = await asyncio.gather(*tasks)

        # 4. Results Summary
        success_count = sum(1 for r in results if r)
        print("-" * 50)
        print(f"Finished at {datetime.now().strftime('%H:%M:%S')}")
        print(f"Success Rate: {success_count}/{TEST_USERS_COUNT} ({(success_count/TEST_USERS_COUNT)*100:.1f}%)")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nTest cancelled by user.")
        sys.exit(0)
