#!/usr/bin/env python3
"""Makes a throwaway Sparkle (Ed25519) key pair for tests: <folder>/ed-private and ed-public, base64."""
import base64
import sys

from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

folder = sys.argv[1]
key = Ed25519PrivateKey.generate()
seed = key.private_bytes(s.Encoding.Raw, s.PrivateFormat.Raw, s.NoEncryption())
public = key.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
open(f"{folder}/ed-private", "w").write(base64.b64encode(seed).decode())
open(f"{folder}/ed-public", "w").write(base64.b64encode(public).decode())
print(base64.b64encode(public).decode())
