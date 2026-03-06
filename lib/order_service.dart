import 'package:cloud_firestore/cloud_firestore.dart';
import 'order_model.dart';

class OrderService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ── Stream all orders by status ──────────────────────────────────────────
  Stream<List<OrderModel>> ordersStream(String status) {
    return _db
        .collection('orders')
        .where('status', isEqualTo: status)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) => OrderModel.fromDoc(d)).toList());
  }

  // ── Stream order counts for dashboard ────────────────────────────────────
  Stream<Map<String, int>> orderCountsStream() {
    return _db.collection('orders').snapshots().map((snap) {
      int placed = 0, inProcess = 0, delivered = 0;
      for (final doc in snap.docs) {
        final status = doc.data()['status'] as String? ?? '';
        if (status == 'placed') placed++;
        else if (status == 'in_process') inProcess++;
        else if (status == 'delivered') delivered++;
      }
      return {
        'placed': placed,
        'in_process': inProcess,
        'delivered': delivered,
        'total': snap.docs.length,
      };
    });
  }

  // ── Update order status ───────────────────────────────────────────────────
  Future<void> updateOrderStatus(String orderId, String newStatus) async {
    await _db.collection('orders').doc(orderId).update({'status': newStatus});
  }

  // ── Stream today's orders only ────────────────────────────────────────────
  Stream<List<OrderModel>> todayOrdersStream() {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    return _db
        .collection('orders')
        .where('createdAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map((d) => OrderModel.fromDoc(d)).toList());
  }
}
