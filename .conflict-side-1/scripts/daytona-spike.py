#!/usr/bin/env python3
"""Daytona VM spike - prove basic sandbox operations work."""

import os
import time
from pathlib import Path

# Load API key from ~/.env
env_path = Path.home() / ".env"
if env_path.exists():
    for line in env_path.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip())

api_key = os.environ.get("DAYTONA_API_KEY")
if not api_key:
    raise SystemExit("DAYTONA_API_KEY not found in environment or ~/.env")

from daytona import Daytona, DaytonaConfig

config = DaytonaConfig(api_key=api_key)
daytona = Daytona(config)

# --- Step 1: Create sandbox and measure latency ---
print("Creating sandbox...")
t0 = time.time()
sandbox = daytona.create()
create_time = time.time() - t0
print(f"  Sandbox ID: {sandbox.id}")
print(f"  Creation time: {create_time:.1f}s")

try:
    # --- Step 2: Run a shell command ---
    print("\nRunning shell command...")
    resp = sandbox.process.exec("echo 'Hello from Daytona!' && uname -a")
    print(f"  exit_code: {resp.exit_code}")
    print(f"  result: {resp.result.strip()}")

    # --- Step 3: Run Python code ---
    print("\nRunning Python code...")
    resp = sandbox.process.code_run('print("Hello World from code!")')
    print(f"  exit_code: {resp.exit_code}")
    print(f"  result: {resp.result.strip()}")

    # --- Step 4: File system operations ---
    print("\nTesting file system...")
    sandbox.process.exec("echo 'spike content' > /home/daytona/test.txt")
    resp = sandbox.process.exec("cat /home/daytona/test.txt")
    print(f"  Write + read roundtrip: {resp.result.strip()}")

    sandbox.fs.create_folder("/home/daytona/workspace", "755")
    resp = sandbox.process.exec("ls -la /home/daytona/")
    print(f"  Home directory:\n{resp.result.strip()}")

    # --- Step 5: Git clone ---
    print("\nTesting git clone...")
    sandbox.git.clone("https://github.com/daytonaio/sdk.git", "/home/daytona/sdk")
    resp = sandbox.process.exec("ls /home/daytona/sdk")
    print(f"  Cloned files: {resp.result.strip()}")

    # --- Step 6: Sandbox info ---
    print("\nSandbox info:")
    print(f"  ID: {sandbox.id}")

    print("\n--- Spike complete ---")

finally:
    print("\nCleaning up sandbox...")
    sandbox.delete()
    print("Done.")
