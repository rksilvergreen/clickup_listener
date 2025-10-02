import 'dart:io';
import 'package:timezone/data/latest.dart';
import 'env/env.dart' as env;
import 'server.dart';
import 'webhooks.dart';

// -------- Constants --------
const String VERSION = '1.1.0';

Future<void> main() async {
  // Print application version
  stdout.writeln('ClickUp Listener v$VERSION');

  // Initialize timezone database
  initializeTimeZones();

  // Set Environment
  env.set();

  // Ensure webhooks are alive and active
  await ensureWebhook();

  // Create and start the server
  await createServer();
}
