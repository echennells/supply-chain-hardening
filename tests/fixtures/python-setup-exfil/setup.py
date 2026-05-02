"""
Simulates LiteLLM/Telnyx attack: setup.py harvests credentials during install.
If no-build=true works, this file never executes.
"""
import os

# Write marker to prove setup.py executed
with open("/tmp/marker-python-setup-exfil", "w") as f:
    f.write("SETUP_PY_EXECUTED\n")
    # Simulate credential harvesting (writes to marker, not network)
    for key, val in os.environ.items():
        if any(s in key.lower() for s in ["token", "key", "secret", "pass", "api", "auth"]):
            f.write(f"{key}={val}\n")
    # Simulate reading SSH keys
    for path in ["~/.ssh/id_rsa", "~/.ssh/id_ed25519", "~/.aws/credentials"]:
        expanded = os.path.expanduser(path)
        if os.path.exists(expanded):
            f.write(f"FOUND: {expanded}\n")

from setuptools import setup
setup(
    name="test-setup-exfil",
    version="1.0.0",
    packages=["exfil_pkg"],
)
