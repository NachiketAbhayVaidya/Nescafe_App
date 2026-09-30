"""
backend_main.py
─────────────────────────────────────────────────────────────
FastAPI backend for the Nescafe app's Razorpay integration.

Endpoints:
  POST /create-order    Flutter calls this right before opening
                         Razorpay Checkout, to get a razorpay_order_id.
  POST /verify-payment   Flutter calls this after Checkout succeeds,
                         to get a server-verified "paid" status.
  POST /webhook          Razorpay calls this directly (server-to-server)
                         as the authoritative source of truth --
                         works even if the Flutter app crashes or
                         loses connection right after payment.
  GET  /health            Simple liveness check.

RUN LOCALLY:
  pip install -r backend_requirements.txt
  cp backend_env_example.txt .env      (then fill in real values)
  uvicorn backend_main:app --reload --port 8000

The Firestore 'orders' collection already has: customerId,
customerName, items, totalAmount, status, createdAt (see
order_service.dart / order_model.dart in lib/). This backend adds
three more fields once payment is confirmed: paymentStatus,
razorpayOrderId, razorpayPaymentId.
─────────────────────────────────────────────────────────────
"""

from fastapi import BackgroundTasks, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware

from backend_models import (
    CreateOrderRequest,
    CreateOrderResponse,
    VerifyPaymentRequest,
    VerifyPaymentResponse,
    SyncPaymentRequest,
    SyncPaymentResponse,
)
from backend_firebase_client import (
    get_order,
    save_razorpay_order_id,
    find_order_by_razorpay_order_id,
    mark_order_paid,
    mark_order_payment_failed,
)
from backend_razorpay_client import (
    create_razorpay_order,
    find_captured_payment_id,
    verify_payment_signature,
    verify_webhook_signature,
)
from backend_config import RAZORPAY_KEY_ID

app = FastAPI(title="Nescafe Payments Backend")

# Mobile apps aren't subject to browser CORS, but this stays permissive
# for now in case of a future web build / local testing via Postman.
# Tighten allow_origins before going to production.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.on_event("startup")
def warm_up():
    # The first Firestore call pays for gRPC/TLS setup; do it at boot so
    # the first real customer request doesn't.
    try:
        get_order("__warmup__")
    except Exception:
        pass


@app.post("/create-order", response_model=CreateOrderResponse)
def create_order(req: CreateOrderRequest, background_tasks: BackgroundTasks):
    order = get_order(req.order_id)
    if order is None:
        raise HTTPException(status_code=404, detail="Order not found in Firestore.")

    # IMPORTANT: the amount charged comes from Firestore's own record of
    # the order, never from a value the client could tamper with.
    amount_rupees = order["totalAmount"]

    razorpay_order = create_razorpay_order(amount_rupees, receipt=req.order_id)
    # Saved after the response is sent so the customer isn't kept waiting.
    # The webhook also finds the order via notes.order_id, so no race.
    background_tasks.add_task(save_razorpay_order_id, req.order_id, razorpay_order["id"])

    return CreateOrderResponse(
        razorpay_order_id=razorpay_order["id"],
        amount=razorpay_order["amount"],
        currency=razorpay_order["currency"],
        key_id=RAZORPAY_KEY_ID,
    )


@app.post("/verify-payment", response_model=VerifyPaymentResponse)
def verify_payment(req: VerifyPaymentRequest):
    # The signature check is a local HMAC -- no Firestore read needed first.
    is_valid = verify_payment_signature(
        req.razorpay_order_id, req.razorpay_payment_id, req.razorpay_signature
    )

    if not is_valid:
        mark_order_payment_failed(req.order_id, "Signature verification failed")
        return VerifyPaymentResponse(success=False, message="Payment could not be verified.")

    mark_order_paid(req.order_id, req.razorpay_payment_id)
    return VerifyPaymentResponse(success=True, message="Payment verified successfully.")


@app.post("/sync-payment", response_model=SyncPaymentResponse)
def sync_payment(req: SyncPaymentRequest):
    """Reconciles one order against Razorpay's own records. Safe to call
    repeatedly and from any client: it only ever marks an order paid when
    Razorpay reports a captured payment for that order's Razorpay order."""
    order = get_order(req.order_id)
    if order is None:
        raise HTTPException(status_code=404, detail="Order not found in Firestore.")
    if order.get("paymentStatus") == "paid":
        return SyncPaymentResponse(paid=True)

    razorpay_order_id = order.get("razorpayOrderId")
    if not razorpay_order_id:
        return SyncPaymentResponse(paid=False)

    payment_id = find_captured_payment_id(razorpay_order_id)
    if payment_id is None:
        return SyncPaymentResponse(paid=False)

    mark_order_paid(req.order_id, payment_id)
    return SyncPaymentResponse(paid=True)


@app.post("/webhook")
async def razorpay_webhook(request: Request):
    """Razorpay's own server calls this directly -- this is the most
    reliable confirmation source, since it doesn't depend on the
    Flutter app staying open/connected after payment."""
    raw_body = await request.body()
    signature = request.headers.get("X-Razorpay-Signature", "")

    if not verify_webhook_signature(raw_body, signature):
        raise HTTPException(status_code=400, detail="Invalid webhook signature.")

    payload = await request.json()
    event = payload.get("event", "")

    if event == "payment.captured":
        payment_entity = payload["payload"]["payment"]["entity"]
        razorpay_order_id = payment_entity["order_id"]
        razorpay_payment_id = payment_entity["id"]

        # Prefer the id we stashed in the Razorpay order's notes; fall back
        # to the Firestore lookup for orders created before that change.
        order_id = (payment_entity.get("notes") or {}).get("order_id")
        if order_id:
            mark_order_paid(order_id, razorpay_payment_id)
        else:
            order = find_order_by_razorpay_order_id(razorpay_order_id)
            if order:
                mark_order_paid(order["id"], razorpay_payment_id)

    elif event == "payment.failed":
        payment_entity = payload["payload"]["payment"]["entity"]
        razorpay_order_id = payment_entity["order_id"]

        order = find_order_by_razorpay_order_id(razorpay_order_id)
        if order:
            mark_order_payment_failed(order["id"], payment_entity.get("error_description", "Payment failed"))

    return {"status": "ok"}
