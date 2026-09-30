import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'api_config.dart';

/// Result handed back to the UI once the Razorpay flow (and the server-side
/// signature verification that follows it) is finished.
class PaymentResult {
  final bool success;
  final String message;
  const PaymentResult(this.success, this.message);
}

/// Wraps the razorpay_flutter Checkout SDK and the two backend calls
/// (`/create-order` and `/verify-payment`) described in backend_README.md,
/// following Razorpay's official Flutter integration steps:
///   1. Create a Razorpay order on the server (never trust a client amount).
///   2. Open Checkout with that order_id.
///   3. On success, verify the signature on the server before treating the
///      order as paid.
class PaymentService {
  final Razorpay _razorpay = Razorpay();
  // One client => keep-alive connection reuse (no repeated TLS handshakes).
  static final http.Client _client = http.Client();

  /// Asks the backend to reconcile [orderId] with Razorpay's own records.
  /// Used when the customer backed out / the app was interrupted mid-payment
  /// and the success callback never arrived. Returns true if the order is
  /// (now) paid; the Firestore stream then flips the tag to "Paid".
  static Future<bool> syncOrder(String orderId) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('${ApiConfig.backendBaseUrl}/sync-payment'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'order_id': orderId}),
          )
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) return false;
      return (jsonDecode(resp.body) as Map<String, dynamic>)['paid'] as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Fire-and-forget ping so a sleeping Render instance starts waking up
  /// while the customer is still browsing the menu.
  static void warmUpBackend() {
    _client
        .get(Uri.parse('${ApiConfig.backendBaseUrl}/health'))
        .timeout(const Duration(seconds: 90))
        .then((_) {}, onError: (_) {});
  }

  Function(PaymentResult)? _onDone;
  String? _pendingOrderId;

  PaymentService() {
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
  }

  /// Starts payment for a Firestore order that has already been created
  /// with `status: 'placed'`. [onDone] is called exactly once, with the
  /// final success/failure outcome (after server-side verification).
  Future<void> startPayment({
    required String orderId,
    required double amount,
    required String businessName,
    required Function(PaymentResult) onDone,
    void Function()? onCheckoutOpening,
  }) async {
    _onDone = onDone;
    _pendingOrderId = orderId;

    try {
      final createResp = await _client
          .post(
            Uri.parse('${ApiConfig.backendBaseUrl}/create-order'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'order_id': orderId}),
          )
          .timeout(const Duration(seconds: 60));

      if (createResp.statusCode != 200) {
        onDone(const PaymentResult(false, 'Could not start payment. Please try again.'));
        return;
      }

      final data = jsonDecode(createResp.body) as Map<String, dynamic>;
      final user = FirebaseAuth.instance.currentUser;

      final options = {
        'key': data['key_id'],
        'amount': data['amount'], // already in paise, from the server
        'currency': data['currency'],
        'name': businessName,
        'order_id': data['razorpay_order_id'],
        'description': 'Canteen order',
        'timeout': 180, // seconds
        'prefill': {
          if (user?.email != null) 'email': user!.email,
          if (user?.phoneNumber != null) 'contact': user!.phoneNumber,
        },
      };

      // The /create-order round trip (which can be slow on a cold backend)
      // is done -- Razorpay's own UI takes over from here.
      onCheckoutOpening?.call();
      _razorpay.open(options);
    } catch (e) {
      onDone(PaymentResult(false, 'Could not start payment: $e'));
    }
  }

  /// Optimistic: Razorpay's success callback already means the money moved,
  /// so the UI is told "success" immediately and the server-side signature
  /// check runs in the background. The Razorpay webhook independently marks
  /// the order paid, so a failed/slow verify call never loses a payment.
  Future<void> _handlePaymentSuccess(PaymentSuccessResponse response) async {
    final orderId = _pendingOrderId;
    final onDone = _onDone;
    if (orderId == null || onDone == null) return;
    _pendingOrderId = null;
    _onDone = null;

    onDone(const PaymentResult(true, 'Payment successful!'));

    final body = jsonEncode({
      'order_id': orderId,
      'razorpay_order_id': response.orderId,
      'razorpay_payment_id': response.paymentId,
      'razorpay_signature': response.signature,
    });

    // Retry to ride out a cold backend; the webhook is the safety net.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final resp = await _client
            .post(
              Uri.parse('${ApiConfig.backendBaseUrl}/verify-payment'),
              headers: {'content-type': 'application/json'},
              body: body,
            )
            .timeout(const Duration(seconds: 20));
        if (resp.statusCode == 200) return;
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  void _handlePaymentError(PaymentFailureResponse response) {
    _onDone?.call(PaymentResult(false, response.message?.trim().isNotEmpty == true ? response.message! : 'Payment failed or was cancelled.'));
    _pendingOrderId = null;
    _onDone = null;
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    // Customer picked an external wallet app; Checkout hands off to it.
    // Nothing to do here -- the success/error handler fires afterwards.
  }

  /// Call from the widget's dispose() to release Razorpay's listeners.
  void dispose() {
    _razorpay.clear();
  }
}
