import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'env/clickup.dart' as clickup;

// -------- ClickUp API helpers --------

Future<void> ensureWebhook() async {
  final existing = await _listWebhooks(clickup.token, clickup.workspace.id);
  final endpointUrl = '${clickup.webhooks.endpointBaseUrl}${clickup.webhooks.endpointRoute}';

  stdout.writeln('[Webhooks] Checking webhooks for endpoint: $endpointUrl');
  stdout.writeln('[Webhooks] Workspace ID: ${clickup.workspace.id}');

  // Find all webhooks pointing to our endpoint
  final matchingWebhooks = existing
      .where(
        (w) => endpointUrl == w['endpoint']?.toString(),
      )
      .toList();

  if (matchingWebhooks.isEmpty) {
    throw Exception(
        'Required webhook not found for endpoint: $endpointUrl. Please create a webhook in ClickUp that points to this endpoint and includes the "taskUpdated" event.');
  }

  stdout.writeln('[Webhooks] Found ${matchingWebhooks.length} webhook(s) for endpoint');

  // Check each matching webhook
  for (final webhook in matchingWebhooks) {
    final webhookId = webhook['id'].toString();
    final status = webhook['status']?.toString();

    stdout.writeln('[Webhooks] Checking webhook ID: $webhookId');

    // Check if this webhook ID is in our configuration
    final configuredWebhook = clickup.webhooks.webhooks
        .where(
          (w) => w.id == webhookId,
        )
        .isNotEmpty;

    if (!configuredWebhook) {
      throw Exception(
          'Webhook $webhookId is not configured in clickup.yaml. Please add this webhook ID to your configuration.');
    }

    // Check if webhook is active, if not activate it
    if (status != 'active') {
      stdout.writeln('[Webhooks] Webhook $webhookId is not active (status: $status), attempting to activate...');
      await _activateWebhook(webhookId);
    } else {
      stdout.writeln('[Webhooks] Webhook $webhookId is already active');
    }
  }

  stdout.writeln('[Webhooks] All webhooks for endpoint are ensured to be active');
}

Future<List<Map<String, dynamic>>> _listWebhooks(String token, String teamId) async {
  final resp = await http.get(
    Uri.parse('${clickup.API_BASE_URL}/team/$teamId/webhook'),
    headers: {
      'Authorization': token,
      'Content-Type': 'application/json',
    },
  );

  if (resp.statusCode >= 200 && resp.statusCode < 300) {
    final data = jsonDecode(resp.body);
    final hooks = (data['webhooks'] as List?) ?? const [];
    return hooks.cast<Map<String, dynamic>>();
  } else {
    stderr.writeln('[Webhooks] Failed to list webhooks (${resp.statusCode}): ${resp.body}');
    throw Exception('ClickUp webhook list failed: ${resp.statusCode}');
  }
}

/// Activates a webhook by setting its status to 'active'
///
/// [webhookId] - The ClickUp webhook ID to activate
Future<void> _activateWebhook(String webhookId) async {
  try {
    final resp = await http.put(
      Uri.parse('${clickup.API_BASE_URL}/webhook/$webhookId'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'status': 'active'}),
    );

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      stdout.writeln('[Webhooks] Webhook $webhookId activated successfully');
    } else {
      stderr.writeln('[Webhooks] Failed to activate webhook $webhookId (${resp.statusCode}): ${resp.body}');
      throw Exception('ClickUp webhook activation failed: ${resp.statusCode}');
    }
  } catch (e) {
    stderr.writeln('[Webhooks] Error activating webhook $webhookId: $e');
    rethrow;
  }
}
