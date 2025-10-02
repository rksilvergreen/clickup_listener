import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:crypto/crypto.dart';
import 'env/clickup.dart' as clickup;
import 'automations/events.dart' as events;
import 'automations/purchase_tags.dart' as purchaseTags;
import 'automations/task_dates.dart' as taskDates;
import 'automations/records.dart' as records;

class ClickupRequestHandler {
  static Future<Response> Function(Request req) get requestHandler => ClickupRequestHandler._()._handleRequest;

  ClickupRequestHandler._();

  Future<Response> _handleRequest(Request req) async {
    final raw = await req.readAsString();

    // print(prettyJsonString(raw));

    // Parse the request body once
    late final body;
    try {
      body = json.decode(raw);
    } catch (e) {
      stderr.writeln('[ClickUp] Error parsing JSON payload: $e');
      return Response.badRequest(body: 'Invalid JSON payload');
    }

    // Validate that body is not null and is a Map<String, dynamic>
    if (body == null || body is! Map<String, dynamic>) {
      stderr.writeln('[ClickUp] Invalid payload structure - expected Map<String, dynamic>');
      return Response.forbidden('Invalid payload structure');
    }

    // Verify webhook signature if secret is configured
    if (clickup.webhooks.webhooks.isNotEmpty) {
      final signature = req.headers['x-signature'];
      if (signature == null) {
        stderr.writeln('[ClickUp] Missing webhook signature');
        return Response.forbidden('Missing signature');
      }

      // Validate that webhook_id is present
      if (body['webhook_id'] == null) {
        stderr.writeln('[ClickUp] Missing webhook_id in payload');
        return Response.forbidden('Missing webhook_id');
      }

      // Extract webhook ID from request body (already validated above)
      final webhookId = body['webhook_id'].toString();
      stdout.writeln('[ClickUp] Found webhook ID in payload: $webhookId');

      // Find the webhook configuration that matches the webhook ID
      final webhook = clickup.webhooks.webhooks.where((w) => w.id == webhookId).firstOrNull;

      if (webhook == null) {
        stderr.writeln('[ClickUp] Unknown webhook ID: $webhookId');
        return Response.forbidden('Unknown webhook ID');
      }

      // Verify signature using the specific webhook's secret
      if (!_verifyWebhookSignature(raw, signature, webhook.secret)) {
        stderr.writeln('[ClickUp] Invalid webhook signature for webhook: $webhookId');
        return Response.forbidden('Invalid signature');
      }

      stdout.writeln('[ClickUp] Webhook signature verified for webhook: $webhookId');
    } else {
      stdout.writeln('[ClickUp] Warning: No webhook secret configured, skipping signature verification');
    }

    // Pull a few helpful fields if present
    final event = body['event']?.toString() ?? 'unknown';
    final taskId = body['task_id']?.toString() ?? body['task']?['id']?.toString();
    stdout.writeln('[ClickUp] event=$event task=$taskId payloadSize=${raw.length}');

    if (['taskCreated', 'taskUpdated', 'taskTagUpdated'].contains(event)) {
      // Note: Runtime config reload removed - automations will be enabled by default
      // or can be controlled via environment variables if needed

      // Route to appropriate handler based on event type
      switch (event) {
        case 'taskCreated':
          await _onTaskCreated(body, taskId);
          break;
        case 'taskUpdated':
          await _onTaskUpdated(body, taskId);
          break;
        case 'taskTagUpdated':
          await _onTaskTagUpdated(body, taskId);
          break;
        default:
          stdout.writeln('[ClickUp] Unhandled event type: $event');
      }
    }
    return Response.ok('ok');
  }

  bool _verifyWebhookSignature(String payload, String signature, String secret) {
    try {
      // ClickUp uses HMAC-SHA256 for webhook signatures
      // The signature is the hex-encoded HMAC of the payload using the secret as key
      final hmac = Hmac(sha256, utf8.encode(secret));
      final digest = hmac.convert(utf8.encode(payload));
      final expectedSignature = digest.toString();

      return signature == expectedSignature;
    } catch (e) {
      stderr.writeln('[ClickUp] Error verifying signature: $e');
      return false;
    }
  }

// -------- Webhook event handlers --------

  Future<Map<String, dynamic>?> _fetchTaskDetails(String taskId) async {
    try {
      final response = await http.get(
        Uri.parse('${clickup.API_BASE_URL}/task/$taskId'),
        headers: {
          'Authorization': clickup.token,
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        // print(prettyJsonString(response.body));

        final taskData = jsonDecode(response.body);
        stdout.writeln('[ClickUp] Successfully fetched task details for: $taskId');
        return taskData;
      } else {
        stderr.writeln('[ClickUp] Failed to fetch task details: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      stderr.writeln('[ClickUp] Error fetching task details: $e');
      return null;
    }
  }

  Future<void> _onTaskCreated(Map<String, dynamic> body, String? taskId) async {
    stdout.writeln('[ClickUp] Handling task created: $taskId');

    if (taskId != null) {
      final taskDetails = await _fetchTaskDetails(taskId);
      if (taskDetails != null) {
        stdout.writeln(
            '[ClickUp] Task created - Name: ${taskDetails['name']}, Status: ${taskDetails['status']?['status']}');

        // Check if this is an event task and handle it accordingly
        // Note: Automation flags removed - automations will run by default
        if (events.isRelevantEventCreate(taskDetails)) {
          stdout.writeln('[ClickUp] Detected relevant event task creation, forwarding to events handler');
          await events.onEventCreated(taskDetails);
        } else if (records.isRelevantRecordCreate(taskDetails)) {
          stdout.writeln('[ClickUp] Detected relevant record task creation, forwarding to records handler');
          await records.onRecordCreated(taskDetails);
        } else if (taskDates.isRelevantDatesCreate(taskDetails)) {
          stdout.writeln('[ClickUp] Detected relevant dates task creation, forwarding to task dates handler');
          await taskDates.onTaskCreated(taskDetails);
        } else {
          stdout.writeln('[ClickUp] Task creation - no automations triggered');
        }
      }
    }
  }

  Future<void> _onTaskUpdated(Map<String, dynamic> body, String? taskId) async {
    stdout.writeln('[ClickUp] Handling task updated: $taskId');

    if (taskId != null) {
      final taskDetails = await _fetchTaskDetails(taskId);
      if (taskDetails != null) {
        stdout.writeln(
            '[ClickUp] Task updated - Name: ${taskDetails['name']}, Status: ${taskDetails['status']?['status']}');

        // Check if this is an event task and handle it accordingly
        // Note: Automation flags removed - automations will run by default
        if (events.isRelevantEventUpdate(taskDetails, body)) {
          stdout.writeln('[ClickUp] Detected event task, forwarding to events handler');
          await events.onEventUpdated(taskDetails, body);
        } else if (taskDates.isRelevantDatesUpdate(body)) {
          stdout.writeln('[ClickUp] Detected relevant dates task update, forwarding to task dates handler');
          await taskDates.onTaskUpdated(taskDetails, body);
        } else {
          stdout.writeln('[ClickUp] Task update - no automations triggered');
        }
      }
    }
  }

  /// Handles when task tags are updated
  ///
  /// [body] - The webhook payload containing tag change information
  /// [taskId] - The ClickUp task ID
  Future<void> _onTaskTagUpdated(Map<String, dynamic> body, String? taskId) async {
    stdout.writeln('[ClickUp] Handling task tag updated: $taskId');

    if (taskId != null) {
      final taskDetails = await _fetchTaskDetails(taskId);
      if (taskDetails != null) {
        final taskName = taskDetails['name'];
        stdout.writeln('[ClickUp] Task tag updated - Name: $taskName, Status: ${taskDetails['status']?['status']}');

        // Extract tag information from the webhook payload
        final historyItems = body['history_items'] as List? ?? [];
        for (final item in historyItems) {
          final field = item['field'];
          final before = item['before'];
          final after = item['after'];

          if (field == 'tag') {
            // Tag was added
            stdout.writeln('[ClickUp] Tag added: $after');
            if (after != null && after is List && after.isNotEmpty) {
              final tagDetails = after[0] as Map<String, dynamic>;
              // Note: Automation flags removed - automations will run by default
              if (purchaseTags.isRelevantPurchaseTagAdded(tagDetails)) {
                await purchaseTags.onPurchaseTagAdded(taskDetails, tagDetails);
              }
            }
          } else if (field == 'tag_removed') {
            // Tag was removed
            stdout.writeln('[ClickUp] Tag removed: $before');
            if (before != null && before is List && before.isNotEmpty) {
              final tagDetails = before[0] as Map<String, dynamic>;
              // Note: Automation flags removed - automations will run by default
              if (purchaseTags.isRelevantPurchaseTagRemoved(tagDetails)) {
                await purchaseTags.onPurchaseTagRemoved(taskDetails, tagDetails);
              }
            }
          }
        }
      }
    }
  }
}

String prettyJsonString(String input) {
  final obj = jsonDecode(input); // throws FormatException if not valid JSON
  const encoder = JsonEncoder.withIndent('  '); // 2-space indent (use '\t' for tabs)
  return encoder.convert(obj);
}
