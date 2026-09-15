"""
backend_firebase_client.py
─────────────────────────────────────────────────────────────
Firebase Admin SDK setup + the one helper this backend needs:
marking a Firestore order as paid once Razorpay confirms it,
and reading an order back to verify its real amount server-side
(never trust an amount sent by the client).
─────────────────────────────────────────────────────────────
"""

import firebase_admin
from firebase_admin import credentials, firestore

from backend_config import FIREBASE_SERVICE_ACCOUNT_PATH

_cred = credentials.Certificate(FIREBASE_SERVICE_ACCOUNT_PATH)
firebase_admin.initialize_app(_cred)

db = firestore.client()


def get_order(order_id: str) -> dict | None:
    """Fetch a Firestore order doc by ID. Returns None if it doesn't exist."""
    snap = db.collection("orders").document(order_id).get()
    if not snap.exists:
        return None
    data = snap.to_dict()
    data["id"] = snap.id
    return data


def save_razorpay_order_id(order_id: str, razorpay_order_id: str) -> None:
    """Stash the Razorpay order ID on the Firestore order, so a webhook
    arriving later (with only the Razorpay order ID, not our Firestore
    order ID) can be matched back to the right order."""
    db.collection("orders").document(order_id).update({
        "razorpayOrderId": razorpay_order_id,
    })


def find_order_by_razorpay_order_id(razorpay_order_id: str) -> dict | None:
    """Used by the webhook handler, which only gets Razorpay's own order ID."""
    query = (
        db.collection("orders")
        .where("razorpayOrderId", "==", razorpay_order_id)
        .limit(1)
        .get()
    )
    for doc in query:
        data = doc.to_dict()
        data["id"] = doc.id
        return data
    return None


def mark_order_paid(order_id: str, razorpay_payment_id: str) -> None:
    db.collection("orders").document(order_id).update({
        "paymentStatus": "paid",
        "razorpayPaymentId": razorpay_payment_id,
        "paidAt": firestore.SERVER_TIMESTAMP,
    })


def mark_order_payment_failed(order_id: str, reason: str) -> None:
    db.collection("orders").document(order_id).update({
        "paymentStatus": "failed",
        "paymentFailureReason": reason,
    })
