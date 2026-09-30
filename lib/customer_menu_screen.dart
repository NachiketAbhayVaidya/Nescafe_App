import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'coffee_loading_animation.dart';
import 'constants.dart';
import 'order_model.dart';
import 'order_service.dart';
import 'payment_service.dart';
import 'policies_screen.dart';

class CustomerMenuScreen extends StatefulWidget {
  const CustomerMenuScreen({super.key});
  @override
  State<CustomerMenuScreen> createState() => _CustomerMenuScreenState();
}

class _CustomerMenuScreenState extends State<CustomerMenuScreen> with WidgetsBindingObserver {
  final OrderService _orders = OrderService();
  final PaymentService _payments = PaymentService();
  final Map<String, _CartEntry> _cart = {};
  int _tab = 0;
  bool _placing = false;
  bool _startingPayment = false;
  String? _pendingOrderId;
  double _pendingAmount = 0;

  StreamSubscription<List<OrderModel>>? _ordersSub;
  List<OrderModel> _latestOrders = const [];
  final Set<String> _syncing = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PaymentService.warmUpBackend();
    bool firstSnapshot = true;
    _ordersSub = _orders.customerOrdersStream().listen((orders) {
      _latestOrders = orders;
      if (firstSnapshot) {
        firstSnapshot = false;
        _reconcileUnpaid(); // app reopened after being killed mid-payment
      }
    }, onError: (_) {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ordersSub?.cancel();
    _payments.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from a UPI app / Razorpay screen: the success callback may
    // have been lost, so ask Razorpay (via the backend) what really happened.
    if (state == AppLifecycleState.resumed) _reconcileUnpaid();
  }

  /// For every unpaid order that had a checkout started, ask the backend to
  /// compare with Razorpay and mark it paid if the money actually arrived.
  /// The Firestore stream then flips the tag to "Paid" on its own.
  void _reconcileUnpaid() {
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    for (final order in _latestOrders) {
      if (order.paymentStatus == 'paid' || order.razorpayOrderId == null) continue;
      if (order.createdAt.isBefore(cutoff) || !_syncing.add(order.id)) continue;
      PaymentService.syncOrder(order.id).whenComplete(() => _syncing.remove(order.id));
    }
  }

  /// After a cancelled/failed checkout the payment may still have gone
  /// through (user backed out of a UPI app after paying), so re-check a few
  /// times while the bank/UPI confirmation catches up.
  void _reconcileAfterCheckoutClosed() {
    for (final seconds in const [2, 8, 20]) {
      Future.delayed(Duration(seconds: seconds), () {
        if (mounted) _reconcileUnpaid();
      });
    }
  }

  int get _cartCount => _cart.values.fold(0, (total, entry) => total + entry.quantity);
  double get _total => _cart.values.fold(0, (total, entry) => total + entry.item.price * entry.quantity);

  void _add(MenuItem item) {
    setState(() {
      final inCart = _cart[item.id]?.quantity ?? 0;
      if (inCart >= item.quantity) return; // can't exceed stock on hand
      if (_cart.containsKey(item.id)) {
        _cart[item.id]!.quantity++;
      } else {
        _cart[item.id] = _CartEntry(item);
      }
    });
  }

  void _change(String itemId, int change) {
    setState(() {
      final entry = _cart[itemId];
      if (entry == null) return;
      final next = entry.quantity + change;
      if (change > 0 && next > entry.item.quantity) return; // stock limit
      entry.quantity = next;
      if (entry.quantity <= 0) _cart.remove(itemId);
    });
  }

  Future<void> _placeOrder() async {
    if (_cart.isEmpty || _placing) return;
    setState(() => _placing = true);
    final orderTotal = _total;
    try {
      final orderId = await _orders.placeOrder(
        items: _cart.values.map((entry) => OrderItem(
          itemId: entry.item.id,
          name: entry.item.name,
          qty: entry.quantity,
          price: entry.item.price,
        )).toList(),
        totalAmount: orderTotal,
      );
      if (!mounted) return;
      setState(() { _cart.clear(); _tab = 1; });
      Navigator.pop(context); // close the cart sheet
      _startPayment(orderId, orderTotal);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not place order. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  /// Opens Razorpay Checkout for [orderId] (already created in Firestore
  /// with status 'placed'). On completion, shows the appropriate result
  /// dialog once the backend has verified the payment signature.
  Future<void> _startPayment(String orderId, double amount) async {
    _pendingOrderId = orderId;
    _pendingAmount = amount;
    setState(() => _startingPayment = true);

    // Retry of an order whose checkout was already started once: it may have
    // been paid without the app finding out. Check first so the customer is
    // never charged twice for the same order.
    final isRetry = _latestOrders.any((o) => o.id == orderId && o.razorpayOrderId != null);
    if (isRetry && await PaymentService.syncOrder(orderId)) {
      if (!mounted) return;
      setState(() => _startingPayment = false);
      _showPaymentResultDialog(const PaymentResult(true, 'Payment successful!'));
      return;
    }
    if (!mounted) return;

    _payments.startPayment(
      orderId: orderId,
      amount: amount,
      businessName: 'College Canteen',
      onCheckoutOpening: () {
        if (mounted) setState(() => _startingPayment = false);
      },
      onDone: (result) {
        if (!mounted) return;
        setState(() => _startingPayment = false);
        if (!result.success) _reconcileAfterCheckoutClosed();
        _showPaymentResultDialog(result);
      },
    );
  }

  void _showPaymentResultDialog(PaymentResult result) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(
              result.success ? Icons.check_circle_rounded : Icons.error_rounded,
              color: result.success ? AppColors.success : AppColors.error,
              size: 40,
            ),
            const SizedBox(height: 10),
            Text(
              result.success ? 'Payment successful!' : 'Payment not completed',
              style: AppTextStyles.heading2,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(result.message, style: AppTextStyles.body, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  if (!result.success && _pendingOrderId != null) {
                    _startPayment(_pendingOrderId!, _pendingAmount);
                  }
                },
                child: Text(result.success ? 'Done' : 'Retry payment'),
              ),
            ),
            if (!result.success) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Pay later from My orders'),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  void _showCart() {
    PaymentService.warmUpBackend(); // re-wake in case it slept meanwhile
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, refresh) => DraggableScrollableSheet(
          initialChildSize: .7,
          minChildSize: .4,
          maxChildSize: .92,
          builder: (context, controller) => Container(
            decoration: const BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
            ),
            child: Column(children: [
              const SizedBox(height: 12),
              Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.textLight, borderRadius: BorderRadius.circular(8))),
              const Padding(padding: EdgeInsets.fromLTRB(24, 18, 24, 8), child: Align(alignment: Alignment.centerLeft, child: Text('Your cart', style: AppTextStyles.heading2))),
              Expanded(
                child: _cart.isEmpty
                  ? const Center(child: Text('Your cart is empty', style: AppTextStyles.body))
                  : ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: _cart.length,
                    separatorBuilder: (_, __) => const Divider(),
                    itemBuilder: (_, index) {
                      final entry = _cart.values.elementAt(index);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(entry.item.name, style: AppTextStyles.heading3.copyWith(fontSize: 15)),
                            Text('₹' + entry.item.price.toStringAsFixed(0) + ' each', style: AppTextStyles.body.copyWith(fontSize: 12)),
                          ])),
                          IconButton(onPressed: () { _change(entry.item.id, -1); refresh(() {}); }, icon: const Icon(Icons.remove_circle_outline)),
                          Text(entry.quantity.toString(), style: AppTextStyles.heading3),
                          IconButton(onPressed: () { _change(entry.item.id, 1); refresh(() {}); }, icon: const Icon(Icons.add_circle, color: AppColors.primary)),
                        ]),
                      );
                    },
                  ),
              ),
              if (_cart.isNotEmpty) SafeArea(
                top: false,
                child: Container(
                  color: AppColors.surface,
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                  child: Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      const Text('Total', style: AppTextStyles.heading3),
                      Text('₹' + _total.toStringAsFixed(0), style: AppTextStyles.heading2.copyWith(color: AppColors.primary)),
                    ]),
                    const SizedBox(height: 12),
                    const PolicyConsentText(
                        prefix: 'By placing this order you agree to our'),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: _placing ? null : _placeOrder,
                      child: _placing ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('Place order'),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final name = user?.displayName?.trim().isNotEmpty == true ? user!.displayName!.trim().split(' ').first : 'Customer';
    // Back is ignored while the payment overlay is up so the customer can't
    // leave the screen mid-request.
    return PopScope(
      canPop: !_startingPayment,
      child: Stack(children: [
      Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          title: Text(_tab == 0 ? 'Hello, ' + name : 'My orders', style: AppTextStyles.heading2),
          actions: [
            if (_tab == 0) Badge(
              isLabelVisible: _cartCount > 0,
              label: Text(_cartCount.toString()),
              child: IconButton(tooltip: 'Cart', icon: const Icon(Icons.shopping_bag_outlined, color: AppColors.textDark), onPressed: _showCart),
            ),
            IconButton(tooltip: 'Policies & Help', icon: const Icon(Icons.info_outline, color: AppColors.textDark), onPressed: () => PoliciesScreen.open(context)),
            IconButton(tooltip: 'Log out', icon: const Icon(Icons.logout_outlined, color: AppColors.textDark), onPressed: () => AuthService().logout()),
          ],
        ),
        body: _tab == 0 ? _buildMenu() : _buildOrders(),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (index) => setState(() => _tab = index),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.restaurant_menu_outlined), selectedIcon: Icon(Icons.restaurant_menu), label: 'Menu'),
            NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'My orders'),
          ],
        ),
      ),
      if (_startingPayment) _buildPaymentLoadingOverlay(),
    ]),
    );
  }

  /// Shown between "place order" and Razorpay Checkout opening -- covers the
  /// /create-order round trip, which can take 30-50s if the backend has spun
  /// down from inactivity (Render free tier cold start).
  Widget _buildPaymentLoadingOverlay() => Container(
    color: Colors.black.withValues(alpha: 0.45),
    child: Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(20)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CoffeeLoadingAnimation(color: AppColors.primary),
          const SizedBox(height: 16),
          Text('Please wait while your payment is being processed',
              textAlign: TextAlign.center, style: AppTextStyles.heading3.copyWith(fontSize: 15)),
          const SizedBox(height: 6),
          Text('Do not press back or refresh at any stage.',
              textAlign: TextAlign.center, style: AppTextStyles.body.copyWith(fontSize: 12)),
        ]),
      ),
    ),
  );

  Widget _buildMenu() => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
    stream: FirebaseFirestore.instance.collection('menu').snapshots(),
    builder: (context, snapshot) {
      if (snapshot.hasError) return const _Message('Unable to load the menu right now.');
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
      final items = snapshot.data!.docs.map(MenuItem.fromDoc).where((item) => item.available).toList()..sort((a, b) => a.name.compareTo(b.name));
      if (items.isEmpty) return const _Message('The menu is being prepared. Please check back soon.');
      return ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
        Text('What would you like today?', style: AppTextStyles.body),
        const SizedBox(height: 16),
        ...items.map((item) => _MenuCard(item: item, onAdd: () => _add(item))),
      ]);
    },
  );

  Widget _buildOrders() => StreamBuilder<List<OrderModel>>(
    stream: _orders.customerOrdersStream(),
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        // ignore: avoid_print
        print('Customer orders stream error: ${snapshot.error}');
        return _Message('Unable to load your orders.\n${snapshot.error}');
      }
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
      if (snapshot.data!.isEmpty) return const _Message('No orders yet. Pick something from the menu to begin.');
      return ListView.separated(
        padding: const EdgeInsets.all(20),
        itemCount: snapshot.data!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, index) {
          final order = snapshot.data![index];
          return _OrderCard(
            order,
            onPayNow: order.paymentStatus == 'paid' || _startingPayment
                ? null
                : () => _startPayment(order.id, order.totalAmount),
          );
        },
      );
    },
  );
}

class MenuItem {
  final String id;
  final String name;
  final String description;
  final double price;
  final bool available;
  final int quantity;
  const MenuItem({required this.id, required this.name, required this.description, required this.price, required this.available, required this.quantity});
  factory MenuItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final quantity = (data['quantity'] as num? ?? 0).toInt();
    final adminAvailable = data['isAvailable'] as bool? ?? data['available'] as bool? ?? true;
    return MenuItem(
      id: doc.id,
      name: (data['name'] ?? data['title'] ?? 'Menu item').toString(),
      description: (data['description'] ?? '').toString(),
      price: (data['price'] as num? ?? 0).toDouble(),
      available: adminAvailable && quantity > 0,
      quantity: quantity,
    );
  }
}

class _CartEntry {
  final MenuItem item;
  int quantity;
  _CartEntry(this.item, [this.quantity = 1]);
}

class _MenuCard extends StatelessWidget {
  final MenuItem item;
  final VoidCallback onAdd;
  const _MenuCard({required this.item, required this.onAdd});
  @override
  Widget build(BuildContext context) {
    final soldOut = item.quantity <= 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFEEEEEE))),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Container(width: 50, height: 50, decoration: BoxDecoration(color: AppColors.secondary, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.lunch_dining_rounded, color: AppColors.primary)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: AppTextStyles.heading3.copyWith(fontSize: 16)),
            if (item.description.isNotEmpty) Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTextStyles.body.copyWith(fontSize: 12)),
            const SizedBox(height: 6),
            Row(children: [
              Text('₹' + item.price.toStringAsFixed(0), style: AppTextStyles.heading3.copyWith(fontSize: 14, color: AppColors.primary)),
              const SizedBox(width: 10),
              Text(
                soldOut ? 'Sold out' : item.quantity.toString() + ' available',
                style: AppTextStyles.label.copyWith(color: soldOut ? AppColors.error : AppColors.textLight),
              ),
            ]),
          ])),
          IconButton.filled(
            onPressed: soldOut ? null : onAdd,
            style: IconButton.styleFrom(backgroundColor: soldOut ? AppColors.textLight : AppColors.primary),
            icon: const Icon(Icons.add),
          ),
        ]),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final OrderModel order;
  final VoidCallback? onPayNow;
  const _OrderCard(this.order, {this.onPayNow});
  @override
  Widget build(BuildContext context) {
    final status = order.status == 'in_process'
      ? (const Color(0xFFF59E0B), 'Preparing')
      : order.status == 'delivered'
        ? (AppColors.success, 'Ready / delivered')
        : (const Color(0xFF3B82F6), 'Order placed');
    final payment = order.paymentStatus == 'paid'
      ? (AppColors.success, 'Paid')
      : order.paymentStatus == 'failed'
        ? (AppColors.error, 'Payment failed')
        : (const Color(0xFFF59E0B), 'Payment pending');
    final shortId = order.id.substring(0, order.id.length < 7 ? order.id.length : 7).toUpperCase();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFEEEEEE))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Order #' + shortId, style: AppTextStyles.heading3.copyWith(fontSize: 15))),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: status.$1.withOpacity(.12), borderRadius: BorderRadius.circular(16)), child: Text(status.$2, style: TextStyle(color: status.$1, fontSize: 12, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: payment.$1.withOpacity(.12), borderRadius: BorderRadius.circular(16)),
          child: Text(payment.$2, style: TextStyle(color: payment.$1, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 10),
        Text(order.items.map((item) => item.qty.toString() + '× ' + item.name).join(', '), style: AppTextStyles.body),
        const SizedBox(height: 10),
        Text('₹' + order.totalAmount.toStringAsFixed(0), style: AppTextStyles.heading3.copyWith(color: AppColors.primary)),
        if (order.paymentStatus != 'paid') ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onPayNow,
              child: const Text('Pay now'),
            ),
          ),
        ],
      ]),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(text, textAlign: TextAlign.center, style: AppTextStyles.body)));
}
