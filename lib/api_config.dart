/// Base URL of the Razorpay payments backend (see backend_main.py).
///
/// Defaults to the deployed Render service, so it works out of the box on
/// any device/network without local backend setup.
///
/// Override at build/run time for local development, e.g.:
///   flutter run --dart-define=BACKEND_BASE_URL=http://10.0.2.2:8000
class ApiConfig {
  static const String backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://nescafe-backend.onrender.com',
  );
}
