import 'package:flutter/material.dart';
import 'constants.dart';

class AdminOrdersScreen extends StatelessWidget {
  final String? initialTab;
  const AdminOrdersScreen({super.key, this.initialTab});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1117),
        title: const Text('Orders',
            style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontWeight: FontWeight.w600)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: const Center(
        child: Text('Orders Screen — Coming Soon',
            style: TextStyle(fontFamily: 'Poppins', color: Colors.white54)),
      ),
    );
  }
}
