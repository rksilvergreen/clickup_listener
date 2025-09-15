import 'package:timezone/data/latest.dart';
import 'env/env.dart' as env;
import 'server.dart';
import 'webhooks.dart';

Future<void> main() async {
  // Initialize timezone database
  initializeTimeZones();

  // Set Environment
  env.set();

  // Ensure webhooks are alive and active
  await ensureWebhook();

  // Create and start the server
  await createServer();
}
