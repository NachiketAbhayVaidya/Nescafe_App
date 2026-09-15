"""
backend_models.py
─────────────────────────────────────────────────────────────
Pydantic request/response models for the FastAPI endpoints.
─────────────────────────────────────────────────────────────
"""

from pydantic import BaseModel


class CreateOrderRequest(BaseModel):
    order_id: str  # the Firestore 'orders' document ID


class CreateOrderResponse(BaseModel):
    razorpay_order_id: str
    amount: int  # in paise, matches what the Razorpay Checkout SDK expects
    currency: str
    key_id: str  # PUBLIC key only -- safe to send to the Flutter app


class VerifyPaymentRequest(BaseModel):
    order_id: str  # the Firestore 'orders' document ID
    razorpay_order_id: str
    razorpay_payment_id: str
    razorpay_signature: str


class VerifyPaymentResponse(BaseModel):
    success: bool
    message: str
