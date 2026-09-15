# Testing the Razorpay API Keys — End-to-End Guide

This walks through verifying your Razorpay **test mode** keys work, from the
raw API keys all the way to a real (fake-money) payment showing up as
`paymentStatus: "paid"` in Firestore. See `backend_README.md` for basic
backend setup/architecture — this file is just the testing flow.

Never use LIVE keys for any of this. Everything below assumes
`RAZORPAY_KEY_ID` starts with `rzp_test_`.

## 0. Get test keys

Razorpay Dashboard -> make sure the mode toggle (top left) is set to
**Test Mode** -> Settings -> API Keys -> Generate Test Key. This gives you
a `Key Id` (`rzp_test_...`) and a `Key Secret` (shown once — copy it).

Test mode keys work without any KYC/activation, so you don't need to wait
on business verification to develop and test the whole flow.

## 1. Sanity-check the key pair directly against Razorpay (no app needed)

Before touching this project's backend at all, confirm the key/secret pair
itself is valid by calling Razorpay's API directly with HTTP Basic Auth:

```
curl -u <RAZORPAY_KEY_ID>:<RAZORPAY_KEY_SECRET> https://api.razorpay.com/v1/payments
```

- `200 OK` with a JSON body (`{"entity":"collection","count":0,"items":[]}`
  on a fresh account) → the keys are valid and active.
- `401` with `"BAD_REQUEST_ERROR" / "Authentication failed"` → wrong key,
  wrong secret, or you copied a live key with a test secret (they don't mix).

This is the fastest way to isolate "my keys are wrong" from "my backend code
is wrong" before debugging anything else.

## 2. Configure the backend's `.env`

```
cd backend
copy ..\backend_env_example.txt .env
```

Fill in the `.env` you just created:
```
RAZORPAY_KEY_ID=rzp_test_xxxxxxxxxxxx
RAZORPAY_KEY_SECRET=xxxxxxxxxxxxxxxxxxxxxxxx
```

Leave `RAZORPAY_WEBHOOK_SECRET` for step 6 — it isn't needed for
`/create-order` or `/verify-payment`.

## 3. Start the backend and confirm it loaded the keys

```
cd backend
.venv\Scripts\uvicorn backend_main:app --reload --port 8000
```

`backend_config.py` raises at startup if the key vars are empty, so if
`uvicorn` starts without the `RuntimeError`, the keys were read. Then:

```
curl http://localhost:8000/health
```
should return `{"status":"ok"}`.

## 4. Test order creation through this backend

`POST /create-order` looks up the order's `totalAmount` in Firestore, so you
need a real order document first — either place one through the Flutter app
(customer menu -> checkout, don't pay yet), or create one manually in the
Firestore `orders` collection with a `totalAmount` field. Then:

```
curl -X POST http://localhost:8000/create-order ^
  -H "Content-Type: application/json" ^
  -d "{\"order_id\": \"<the firestore order doc id>\"}"
```

Expected response:
```
{"razorpay_order_id":"order_XXXXXXXXXXXX","amount":<paise>,"currency":"INR","key_id":"rzp_test_..."}
```

A `razorpay_order_id` coming back confirms the key pair can authenticate
*and* create orders (some restricted/incomplete accounts can authenticate
but not create orders, so this is a stronger check than step 1 alone). You
can also see the order appear in Razorpay Dashboard -> Test Mode -> Orders.

If this fails with a Razorpay error, the response detail will usually name
the problem (bad auth, invalid amount, etc.) — `amount` must be a positive
integer in paise, which `create_razorpay_order()` already handles.

## 5. Run a full test payment from the Flutter app

Run the app pointed at your local backend (`lib/api_config.dart` defaults to
`http://10.0.2.2:8000` for the Android emulator; use your LAN IP for a
physical device, or `--dart-define=BACKEND_BASE_URL=...`).

Place an order, proceed to checkout — this opens Razorpay's Checkout SDK
using the `key_id` + `razorpay_order_id` from step 4. Because the key is a
`rzp_test_` key, Checkout runs in test mode and accepts Razorpay's published
test payment methods instead of real money:

| Method | Test value |
|---|---|
| Card | `4111 1111 1111 1111`, any future expiry, any 3-digit CVV |
| Card (needs OTP) | OTP `1234` when prompted |
| UPI (success) | VPA `success@razorpay` |
| UPI (failure) | VPA `failure@razorpay` |
| Netbanking | Pick any test bank, then choose "Success" on the simulated bank page |

(These are Razorpay's own documented test values — double-check
Razorpay's current Test Mode docs if any of them stop working, as they can
change.)

On success, `payment_service.dart` automatically calls `/verify-payment`
with the payment ID + signature Checkout returns.

## 6. Confirm signature verification actually happened

Two ways to confirm this isn't just trusting the client:

- Check the FastAPI logs/response from `/verify-payment` — a genuine
  success returns `{"success": true, "message": "Payment verified successfully."}`.
- Check Firestore: the order doc should now have `paymentStatus: "paid"` and
  a `razorpayPaymentId` field (see `mark_order_paid` in
  `backend_firebase_client.py`).

To confirm the check is real (not a no-op), try `/verify-payment` with a
tampered `razorpay_signature` (edit one character) — it must come back with
`success: false` and the order must get `paymentStatus` set to a failed
state via `mark_order_payment_failed`, never `"paid"`.

## 7. Test the webhook path (independent confirmation)

The webhook is the second, server-to-server confirmation path — it should
work even if the app crashes right after payment.

1. Expose your local backend: `ngrok http 8000` → note the `https://...`
   forwarding URL.
2. Razorpay Dashboard -> Settings -> Webhooks -> Add New Webhook:
   - URL: `https://<ngrok-id>.ngrok.io/webhook`
   - Active events: `payment.captured`, `payment.failed`
   - Copy the generated **Webhook Secret** into `.env` as
     `RAZORPAY_WEBHOOK_SECRET`, then restart uvicorn so it picks it up.
3. Repeat a test payment (step 5). Razorpay Dashboard -> Webhooks -> your
   webhook -> recent deliveries should show a `200` response from your
   backend.
4. Firestore should show the same `paymentStatus: "paid"` update — this
   time driven by `/webhook`, not `/verify-payment`.

If the webhook delivery shows `400 Invalid webhook signature`, the secret in
`.env` doesn't match the one shown in the Dashboard for that specific
webhook (each webhook URL gets its own secret).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `401 Authentication failed` on any Razorpay call | Key/secret typo, mismatched test/live pair, or extra whitespace copied into `.env` |
| Backend raises `RuntimeError` on startup | `.env` missing or not in `backend/` working directory when uvicorn starts |
| `/create-order` 404s "Order not found" | Wrong/nonexistent Firestore `order_id`, or hitting the wrong Firebase project |
| Checkout opens but no test methods listed above work | Confirm the `key` field in Checkout options is really the `rzp_test_` key (check the Dashboard is in Test Mode, and `key_id` in the `/create-order` response) |
| Webhook never arrives | ngrok tunnel restarted (URL changes each run — must be re-saved in Dashboard) or backend not reachable from the internet |
