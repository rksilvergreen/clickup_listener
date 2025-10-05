import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../env/clickup.dart' as clickup;

/// Checks if a task is of type "record"
///
/// [taskDetails] - Complete task details from ClickUp API
/// Returns true if the task is a record, false otherwise
bool isRecordTask(Map<String, dynamic> taskDetails) {
  // Check if the task's custom_item_id matches the record task type ID
  final customItemId = taskDetails['custom_item_id']?.toString();
  return customItemId == clickup.workspace.taskTypeIds.record;
}

/// Checks if a newly created record task is relevant for automation
///
/// [taskDetails] - Complete task details from ClickUp API
/// Returns true if the task is a record and should have timestamp set
bool isRelevant_RecordCreate(Map<String, dynamic> taskDetails) {
  // First check if this is a record task
  if (!isRecordTask(taskDetails)) {
    return false;
  }

  // For record tasks, we always want to set the timestamp when created
  return true;
}

// -------- Record handling functions --------

/// Handles when a new record task is created
///
/// This function sets the timestamp custom field to the current time
/// for newly created record tasks.
///
/// [taskDetails] - Complete task details from ClickUp API
Future<void> onRecordCreated(Map<String, dynamic> taskDetails) async {
  final taskId = taskDetails['id'];
  final taskName = taskDetails['name'];

  stdout.writeln('[Records] Processing new record creation for: $taskName (ID: $taskId)');

  // Set the timestamp to current time
  final currentTime = DateTime.now();
  await setTimestamp(taskId, currentTime);

  stdout.writeln('[Records] Record creation processing completed for: $taskName');
}

/// Handles updates to ClickUp tasks of type "record"
///
/// This function checks if the update is relevant and invokes the appropriate handler.
///
/// [taskDetails] - Complete task details from ClickUp API
/// [webhookBody] - Original webhook payload for context
Future<void> onRecordUpdated(Map<String, dynamic> taskDetails, Map<String, dynamic> webhookBody) async {
  final taskId = taskDetails['id'];
  final taskName = taskDetails['name'];

  stdout.writeln('[Records] Processing record update for: $taskName (ID: $taskId)');

  // For now, we don't handle updates to record tasks
  // This could be extended in the future to update timestamp on specific changes
  stdout.writeln('[Records] Record update processing completed for: $taskName (no actions taken)');
}

/// Updates the "Timestamp" custom field in ClickUp for a given task
///
/// [taskId] - The ClickUp task ID
/// [timestamp] - The DateTime to set as the timestamp, or null to clear the field
Future<void> setTimestamp(String taskId, DateTime? timestamp) async {
  if (timestamp == null) {
    // Use DELETE endpoint to clear the field
    try {
      final response = await http.delete(
        Uri.parse('${clickup.API_BASE_URL}/task/$taskId/field/${clickup.workspace.customFieldIds.timestamp}'),
        headers: {
          'Authorization': clickup.token,
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        stdout.writeln('[Records] Successfully cleared Timestamp for task $taskId');
      } else {
        stderr.writeln(
            '[Records] Failed to clear Timestamp for task $taskId. Status: ${response.statusCode}, Response: ${response.body}');
      }
    } catch (e) {
      stderr.writeln('[Records] Error clearing Timestamp for task $taskId: $e');
    }
    return;
  }

  try {
    // Prepare the request body
    final requestBody = {
      "value_options": {"time": true},
      "value": timestamp.millisecondsSinceEpoch
    };

    // Make the API call to update the custom field
    final response = await http.post(
      Uri.parse('${clickup.API_BASE_URL}/task/$taskId/field/${clickup.workspace.customFieldIds.timestamp}'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      stdout.writeln('[Records] Successfully updated Timestamp for task $taskId to $timestamp');
    } else {
      stderr.writeln(
          '[Records] Failed to update Timestamp for task $taskId. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[Records] Error updating Timestamp for task $taskId: $e');
  }
}
