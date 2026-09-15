"""
create_admin_user.py
─────────────────────────────────────────────────────────────
Creates a Firebase Auth account with the given email/password
and immediately grants it admin custom claims — so it logs
straight into the Admin Dashboard instead of the customer menu.

Safe to re-run: if the account already exists, it just resets
the password and sets the admin claim instead of failing.
─────────────────────────────────────────────────────────────
"""

import subprocess
import sys

try:
    import firebase_admin
    from firebase_admin import credentials, auth
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "firebase-admin", "--quiet"])
    import firebase_admin
    from firebase_admin import credentials, auth

ADMIN_EMAIL = "aatulk123@yahoo.com"
ADMIN_PASSWORD = "nascafe@1982"

# Note: the file on disk is actually named serviceAccountKey.json.json
# (double extension).
cred = credentials.Certificate("C:\\Users\\Nachiket\\nescafe_app\\serviceAccountKey.json.json")
firebase_admin.initialize_app(cred)

try:
    user = auth.create_user(email=ADMIN_EMAIL, password=ADMIN_PASSWORD, email_verified=True)
    uid = user.uid
    print(f"Created new account for {ADMIN_EMAIL} -- UID: {uid}")
except auth.EmailAlreadyExistsError:
    existing = auth.get_user_by_email(ADMIN_EMAIL)
    uid = existing.uid
    print(f"Account already existed for {ADMIN_EMAIL} -- UID: {uid}")
    auth.update_user(uid, password=ADMIN_PASSWORD)
    print("Password updated to match the requested value.")

auth.set_custom_user_claims(uid, {"role": "admin"})
print(f"Admin claim set for UID: {uid}")
print("Done! This account will now be routed to the Admin Dashboard on login.")
