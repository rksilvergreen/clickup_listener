import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'env/clickup.dart' as clickup;
import 'request_handler.dart';

// -------- Constants --------
const int DEFAULT_PORT = 8080;

// -------- Server setup and routing --------

Future<HttpServer> createServer() async {
  final router = Router();

  // Health endpoint
  router.get('/health', (Request req) => Response.ok('ok'));

  router.post(clickup.webhooks.endpointRoute, ClickupRequestHandler.requestHandler);

  // Get port from environment variable or use default
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? DEFAULT_PORT;

  // Start HTTP server
  final server = await serve(
    logRequests().addHandler(router),
    InternetAddress.anyIPv4,
    port,
  );

  stdout.writeln('Listening on http://${server.address.host}:${server.port}  (public: http://localhost:$port)');

  return server;
}