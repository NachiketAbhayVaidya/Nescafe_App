import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'order_model.dart';

class OrderService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DateTime _startOfToday() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// Orders with the given status, placed today only (resets at local
  /// midnight). Used by the New / Preparing / Delivered tabs.
  Stream<List<OrderModel>> ordersStream(String status) {
    final start = _startOfToday();
    return _db
        .collection('orders')
        .where('status', isEqualTo: status)
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map(OrderModel.fromDoc).toList());
  }

  /// Emits an order each time it becomes paid while this stream is being
  /// listened to (not for orders that were already paid when it started).
  /// Drives the admin device's "new paid order" beep.
  Stream<OrderModel> newlyPaidOrdersStream() async* {
    final start = _startOfToday();
    final lastPaymentStatus = <String, String>{};
    var firstSnapshot = true;
    await for (final snap in _db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .snapshots()) {
      for (final doc in snap.docs) {
        final order = OrderModel.fromDoc(doc);
        final previous = lastPaymentStatus[order.id];
        lastPaymentStatus[order.id] = order.paymentStatus;
        if (!firstSnapshot && order.paymentStatus == 'paid' && previous != 'paid') {
          yield order;
        }
      }
      firstSnapshot = false;
    }
  }

  /// Status counts for TODAY only — resets to zero at local midnight.
  /// Powers the "Total Orders Today" banner and the status cards.
  Stream<Map<String, int>> orderCountsStream() {
    final start = _startOfToday();
    return _db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .snapshots()
        .map((snap) {
      var placed = 0, inProcess = 0, delivered = 0;
      for (final doc in snap.docs) {
        final status = doc.data()['status'];
        if (status == 'placed') {
          placed++;
        } else if (status == 'in_process') {
          inProcess++;
        } else if (status == 'delivered') {
          delivered++;
        }
      }
      return {'placed': placed, 'in_process': inProcess, 'delivered': delivered, 'total': snap.docs.length};
    });
  }

  /// Every order ever placed, newest first. Nothing is ever deleted from
  /// 'orders' — this just isn't filtered to today, so it's the permanent
  /// record. The History tab groups this list by date on the client.
  Stream<List<OrderModel>> historyOrdersStream() => _db
      .collection('orders')
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map(OrderModel.fromDoc).toList());

  Future<void> updateOrderStatus(String orderId, String newStatus) => _db.collection('orders').doc(orderId).update({'status': newStatus});

  /// Creates the order and returns its Firestore document ID, which the
  /// caller passes to PaymentService to kick off the Razorpay Checkout flow.
  Future<String> placeOrder({required List<OrderItem> items, required double totalAmount}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Not signed in');
    final docRef = await _db.collection('orders').add({
      'customerId': user.uid,
      'customerName': user.displayName?.trim().isNotEmpty == true ? user.displayName!.trim() : (user.email?.split('@').first ?? 'Customer'),
      'items': items.map((item) => item.toMap()).toList(),
      'totalAmount': totalAmount,
      'status': 'placed',
      'paymentStatus': 'pending',
      'isPrebooked': false,
      'prebookTime': null,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return docRef.id;
  }

  /// Called when the admin accepts a 'placed' order: atomically decrements
  /// the stock quantity for each menu item and moves the order to
  /// 'in_process'. Uses a transaction so stock never goes negative or gets
  /// double-counted if accepted twice.
  Future<void> acceptOrder(String orderId) async {
    final orderRef = _db.collection('orders').doc(orderId);
    await _db.runTransaction((transaction) async {
      final orderSnap = await transaction.get(orderRef);
      if (!orderSnap.exists) throw StateError('Order not found');
      final data = orderSnap.data() as Map<String, dynamic>;
      if (data['status'] != 'placed') return; // already accepted/handled

      final items = (data['items'] as List<dynamic>? ?? [])
          .map((e) => OrderItem.fromMap(e as Map<String, dynamic>))
          .toList();

      // All reads must happen before any writes inside a transaction.
      final menuSnaps = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final item in items) {
        menuSnaps.add(await transaction.get(
          _db.collection('menu').doc(item.itemId) as DocumentReference<Map<String, dynamic>>,
        ));
      }

      for (var i = 0; i < items.length; i++) {
        final menuSnap = menuSnaps[i];
        if (!menuSnap.exists) continue;
        final currentQty = (menuSnap.data()?['quantity'] as num? ?? 0).toInt();
        final newQty = currentQty - items[i].qty < 0 ? 0 : currentQty - items[i].qty;
        transaction.update(menuSnap.reference, {
          'quantity': newQty,
          'isAvailable': newQty > 0,
        });
      }

      transaction.update(orderRef, {'status': 'in_process'});
    });
  }

  Stream<List<OrderModel>> customerOrdersStream() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return Stream.value(const []);
    return _db.collection('orders').where('customerId', isEqualTo: user.uid).orderBy('createdAt', descending: true).snapshots().map((snap) => snap.docs.map(OrderModel.fromDoc).toList());
  }
}
