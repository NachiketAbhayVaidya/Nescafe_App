import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Stream to listen to auth state changes
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Get current user
  User? get currentUser => _auth.currentUser;

  // ─── CHECK IF USER IS ADMIN (via custom claims) ───────────────────────────
  Future<bool> isAdmin() async {
    final user = _auth.currentUser;
    if (user == null) return false;

    // Force refresh to get latest claims
    final token = await user.getIdTokenResult(true);
    return token.claims?['role'] == 'admin';
  }

  // ─── LOGIN ─────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      final user = credential.user!;

      // Force refresh token to get latest custom claims
      final token = await user.getIdTokenResult(true);
      final role = token.claims?['role'] ?? 'customer';

      return {'success': true, 'role': role};
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'error': _handleAuthError(e.code)};
    } catch (e) {
      return {'success': false, 'error': 'Something went wrong. Try again.'};
    }
  }

  // ─── SIGNUP (customers only) ───────────────────────────────────────────────
  Future<Map<String, dynamic>> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      final user = credential.user!;

      // Update display name
      await user.updateDisplayName(name.trim());

      // Save user to Firestore with role = customer
      await _firestore.collection('users').doc(user.uid).set({
        'name': name.trim(),
        'email': email.trim(),
        'role': 'customer',
        'createdAt': FieldValue.serverTimestamp(),
      });

      return {'success': true, 'role': 'customer'};
    } on FirebaseAuthException catch (e) {
      return {'success': false, 'error': _handleAuthError(e.code)};
    } catch (e) {
      return {'success': false, 'error': 'Something went wrong. Try again.'};
    }
  }

  // ─── LOGOUT ────────────────────────────────────────────────────────────────
  Future<void> logout() async {
    await _auth.signOut();
  }

  // ─── ERROR HANDLER ─────────────────────────────────────────────────────────
  String _handleAuthError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
        return 'Incorrect password.';
      case 'invalid-email':
        return 'Invalid email address.';
      case 'email-already-in-use':
        return 'An account already exists with this email.';
      case 'weak-password':
        return 'Password must be at least 6 characters.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'invalid-credential':
        return 'Invalid email or password.';
      default:
        return 'Authentication failed. Please try again.';
    }
  }
}
