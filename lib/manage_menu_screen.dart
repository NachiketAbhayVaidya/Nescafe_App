import 'package:flutter/material.dart';

class ManageMenuScreen extends StatelessWidget {
  const ManageMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1117),
        title: const Text('Manage Menu',
            style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontWeight: FontWeight.w600)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: const Center(
        child: Text('Menu Management — Coming Soon',
            style: TextStyle(fontFamily: 'Poppins', color: Colors.white54)),
      ),
    );
  }
}
