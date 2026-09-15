"""
backend_razorpay_client.py
─────────────────────────────────────────────────────────────
Thin wrapper around the Razorpay Python SDK: create an order,
and verify a payment's signature server-side.

The signature check is the entire point of having a backend at
all — it's cryptographic proof, using a secret key the Flutter
app never sees, that a payment genuinely went through. That's
exactly the "no confirmation" gap the deep-link approach had.
─────────────────────────────────────────────────────────────
"""

import razorpay

from backend_config import RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET, RAZORPAY_WEBHOOK_SECRET

client = razorpay.Client(auth=(RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET))


def create_razorpay_order(amount_rupees: float, receipt: str) -> dict:
    """Amount must be in paise (INR smallest unit) per Razorpay's API."""
    amount_paise = int(round(amount_rupees * 100))
    return client.order.create({
        "amount": amount_paise,
        "currency": "INR",
        "receipt": receipt,
        "payment_capture": 1,  # auto-capture on successful payment
    })


def verify_payment_signature(razorpay_order_id: str, razorpay_payment_id: str, razorpay_signature: str) -> bool:
    """Called after the Flutter app's Razorpay Checkout SDK returns a
    success callback. Returns True only if the signature genuinely
    matches — i.e. the payment is real, not just claimed by the client."""
    try:
        client.utility.verify_payment_signature({
            "razorpay_order_id": razorpay_order_id,
            "razorpay_payment_id": razorpay_payment_id,
            "razorpay_signature": razorpay_signature,
        })
        return True
    except razorpay.errors.SignatureVerificationError:
        return False


def verify_webhook_signature(raw_body: bytes, received_signature: str) -> bool:
    """Verifies Razorpay's server-to-server webhook payload signature.
    This uses a SEPARATE secret from the API key — set it up in the
    Razorpay Dashboard under Settings -> Webhooks when you add the
    webhook URL, and put that value in RAZORPAY_WEBHOOK_SECRET."""
    try:
        client.utility.verify_webhook_signature(
            raw_body.decode("utf-8"), received_signature, RAZORPAY_WEBHOOK_SECRET
        )
        return True
    except razorpay.errors.SignatureVerificationError:
        return False
