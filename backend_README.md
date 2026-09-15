# Nescafe Payments Backend (FastAPI + Razorpay)

Handles the server side of Razorpay integration: creating orders, verifying
payment signatures, and confirming payments via webhook -- the piece that
was missing from the pure UPI deep-link approach (no way to know if a
payment actually succeeded).

## Files

- `backend_main.py` -- the FastAPI app and all three endpoints
- `backend_config.py` -- loads secrets from `.env`
- `backend_razorpay_client.py` -- Razorpay order creation + signature verification
- `backend_firebase_client.py` -- reads/writes the Firestore `orders` collection
- `backend_models.py` -- request/response schemas
- `backend_requirements.txt` -- Python dependencies
- `backend_env_example.txt` -- template for your real `.env` file

## Setup


1. Create a virtual environment and install dependencies (keeps this from
   touching/downgrading any packages you have installed globally):
   ```
   python -m venv backend/.venv
   backend\.venv\Scripts\pip install -r backend_requirements.txt "setuptools<81"
   ```
   (`setuptools<81` is needed because the `razorpay` package still imports
   the now-removed `pkg_resources` API.)

2. Copy the env template and fill in real values:
   ```
   copy backend_env_example.txt .env
   ```
   You'll need, from the Razorpay Dashboard:
   - `RAZORPAY_KEY_ID` / `RAZORPAY_KEY_SECRET` -- use TEST keys while developing
   - `RAZORPAY_WEBHOOK_SECRET` -- generated when you set up the webhook (step 4)

3. Run the server locally (the Python files live in `backend/`):
   ```
   cd backend
   .venv\Scripts\uvicorn backend_main:app --reload --port 8000
   ```
   Visit `http://localhost:8000/health` to confirm it's running, and
   `http://localhost:8000/docs` for the interactive API docs FastAPI
   generates automatically.

4. Set up the Razorpay webhook (once you're ready to test end-to-end):
   - Your laptop's `localhost` isn't reachable from Razorpay's servers, so for
     local testing, use a tunnel tool like `ngrok http 8000` to get a public
     URL, e.g. `https://abcd1234.ngrok.io`
   - In Razorpay Dashboard -> Settings -> Webhooks, add
     `https://abcd1234.ngrok.io/webhook`, subscribe to `payment.captured`
     and `payment.failed`, and copy the generated secret into your `.env`
     as `RAZORPAY_WEBHOOK_SECRET`

## How the flow works

1. Customer places an order in the Flutter app (writes to Firestore as before)
2. Flutter calls `POST /create-order` with the Firestore order ID
3. Backend reads the order's real `totalAmount` from Firestore (never trusts
   a client-supplied amount), creates a Razorpay order, returns the
   `razorpay_order_id` + public `key_id`
4. Flutter opens Razorpay's Checkout SDK (`razorpay_flutter` package) with
   those values
5. Customer pays. On success, Razorpay's SDK returns a payment ID + signature
   to the Flutter app
6. Flutter calls `POST /verify-payment` with those values
7. Backend verifies the signature server-side (this is the actual proof of
   payment -- it's cryptographically impossible to fake without the secret
   key, which never leaves this backend)
8. If valid, Firestore's order doc gets `paymentStatus: "paid"`
9. Separately, Razorpay's webhook also hits `/webhook` directly -- this is a
   second, independent confirmation path that works even if the Flutter app
   crashes or loses network right after step 5

## Flutter side

Done. `lib/payment_service.dart` wraps the `razorpay_flutter` SDK and calls
this backend's `/create-order` and `/verify-payment` endpoints; it's wired
into `customer_menu_screen.dart`'s checkout flow (replacing the old static
QR image). The backend URL it talks to is set in `lib/api_config.dart` --
update it (or pass `--dart-define=BACKEND_BASE_URL=...`) once this backend
is deployed somewhere reachable from a real device.

## Not done yet / next steps

- **Deployment**: this only runs locally right now. Before this goes live,
  it needs to be deployed somewhere reachable 24/7 (Railway, Render, Google
  Cloud Run all have free/cheap tiers) so the webhook URL is permanent
  instead of an ngrok tunnel.
- **Real Razorpay keys**: still waiting on Atul's KYC approval for live keys
  -- test keys work fully for development in the meantime.
