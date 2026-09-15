"""
backend_config.py
─────────────────────────────────────────────────────────────
Loads all secrets/config from environment variables (via a .env
file) instead of hardcoding them in source — so this can be
safely committed to git without leaking real keys.
─────────────────────────────────────────────────────────────
"""

import os
from dotenv import load_dotenv

load_dotenv()

RAZORPAY_KEY_ID = os.getenv("RAZORPAY_KEY_ID", "")
RAZORPAY_KEY_SECRET = os.getenv("RAZORPAY_KEY_SECRET", "")
RAZORPAY_WEBHOOK_SECRET = os.getenv("RAZORPAY_WEBHOOK_SECRET", "")

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_firebase_path = os.getenv("FIREBASE_SERVICE_ACCOUNT_PATH", "./serviceAccountKey.json.json")
FIREBASE_SERVICE_ACCOUNT_PATH = (
    _firebase_path
    if os.path.isabs(_firebase_path)
    else os.path.normpath(os.path.join(_REPO_ROOT, _firebase_path))
)

if not RAZORPAY_KEY_ID or not RAZORPAY_KEY_SECRET:
    raise RuntimeError(
        "RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET are not set. "
        "Copy backend_env_example.txt to .env and fill in your Razorpay test/live keys."
    )
