import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../env/clickup.dart' as clickup;

/// Checks if a task is of type "meeting"
///
/// [taskDetails] - Complete task details from ClickUp API
/// Returns true if the task is a meeting, false otherwise
bool isMeetingTask(Map<String, dynamic> taskDetails) {
  // Check if the task's custom_item_id matches the meeting task type ID
  final customItemId = taskDetails['custom_item_id']?.toString();
  return customItemId == clickup.workspace.taskTypeIds.meeting;
}

/// Checks if a meeting task update is relevant (involves changes to due date)
///
/// [taskDetails] - Complete task details from ClickUp API
/// [webhookBody] - Original webhook payload for context
/// Returns true if the update involves changes to due date
bool isRelevant_MeetingUpdate_DueDate(Map<String, dynamic> taskDetails, Map<String, dynamic> webhookBody) {
  // First check if this is a meeting task
  if (!isMeetingTask(taskDetails)) {
    return false;
  }

  // Check if there are any history items
  final historyItems = webhookBody['history_items'] as List? ?? [];
  if (historyItems.isEmpty) {
    return false;
  }

  // Check each history item for due date changes
  for (final item in historyItems) {
    final field = item['field'];

    // Check for due date field changes
    if (field == 'due_date') {
      return true;
    }
  }

  return false;
}

/// Checks if a meeting task update is relevant (involves changes to pre-meeting tasks)
///
/// [taskDetails] - Complete task details from ClickUp API
/// [webhookBody] - Original webhook payload for context
/// Returns true if the update involves changes to pre-meeting tasks
bool isRelevant_MeetingUpdate_PreMeetingTasks(Map<String, dynamic> taskDetails, Map<String, dynamic> webhookBody) {
  // First check if this is a meeting task
  if (!isMeetingTask(taskDetails)) {
    return false;
  }

  // Check if there are any history items
  final historyItems = webhookBody['history_items'] as List? ?? [];
  if (historyItems.isEmpty) {
    return false;
  }

  // Check each history item for pre-meeting tasks field changes
  for (final item in historyItems) {
    final field = item['field'];

    // Check for custom field changes
    if (field == 'custom_field') {
      final customField = item['custom_field'];
      if (customField != null && customField['id'] == clickup.workspace.customFieldIds.preMeetingTasks) {
        return true;
      }
    }
  }

  return false;
}

/// Handles updates to ClickUp tasks of type "meeting" due date changes
///
/// This function checks if the due date has changed and conditionally updates pre-meeting tasks:
/// - First Priority: If a pre-meeting task has the same due date as the old meeting due date, always update it to the new meeting due date (even if null)
/// - Second Priority: For other tasks, only update if the new date is earlier than their current date (or if they have no due date)
///
/// [taskDetails] - Complete task details from ClickUp API
/// [webhookBody] - Original webhook payload for context
Future<void> onMeetingUpdated_DueDate(Map<String, dynamic> taskDetails, Map<String, dynamic> webhookBody) async {
  final taskId = taskDetails['id'];
  final taskName = taskDetails['name'];

  stdout.writeln('[Meetings] Processing meeting update for: $taskName (ID: $taskId)');

  // Check what changed in the webhook
  final historyItems = webhookBody['history_items'] as List? ?? [];

  for (final item in historyItems) {
    final field = item['field'];
    final before = item['before'];
    final after = item['after'];

    if (field == 'due_date') {
      stdout.writeln('[Meetings] Due date changed from $before to $after');

      // Parse the previous and new due dates from the webhook
      final previousMeetingDueDate = _parseTimestamp(before);
      final newMeetingDueDate = _parseTimestamp(after);

      // Use the unified conditional update function for all cases
      await _conditionallyUpdatePreMeetingTasks(taskDetails, newMeetingDueDate, previousMeetingDueDate);
    }
  }

  stdout.writeln('[Meetings] Meeting update processing completed for: $taskName');
}

/// Handles when pre-meeting tasks are added to a meeting
///
/// This function checks if new pre-meeting tasks were added and conditionally updates their due dates:
/// - If meeting's due date is null, do nothing
/// - If new pre-meeting task has no due date or its due date is later than the meeting's due date, set it to the meeting's due date
///
/// [taskDetails] - Complete task details from ClickUp API
/// [webhookBody] - Original webhook payload for context
Future<void> onMeetingUpdated_PreMeetingTasks(
    Map<String, dynamic> taskDetails, Map<String, dynamic> webhookBody) async {
  final taskId = taskDetails['id'];
  final taskName = taskDetails['name'];

  stdout.writeln('[Meetings] Processing pre-meeting task addition for: $taskName (ID: $taskId)');

  // Get the meeting's current due date
  final meetingDueDate = _parseTimestamp(taskDetails['due_date']);

  if (meetingDueDate == null) {
    stdout.writeln('[Meetings] Meeting has no due date, skipping pre-meeting task updates');
    return;
  }

  stdout.writeln('[Meetings] Meeting due date: $meetingDueDate');

  // Check what changed in the webhook
  final historyItems = webhookBody['history_items'] as List? ?? [];

  for (final item in historyItems) {
    final field = item['field'];
    final before = item['before'];
    final after = item['after'];

    if (field == 'custom_field') {
      final customField = item['custom_field'];
      if (customField != null && customField['id'] == clickup.workspace.customFieldIds.preMeetingTasks) {
        stdout.writeln('[Meetings] Pre-meeting tasks field changed from $before to $after');

        // Get the newly added task IDs
        final beforeList = (before as List?) ?? [];
        final afterList = (after as List?) ?? [];

        // Find newly added tasks
        final newlyAddedTasks = afterList.where((taskId) => !beforeList.contains(taskId)).cast<String>().toList();

        if (newlyAddedTasks.isNotEmpty) {
          stdout.writeln('[Meetings] Found ${newlyAddedTasks.length} newly added pre-meeting tasks');
          await _updateNewlyAddedPreMeetingTasks(newlyAddedTasks, meetingDueDate);
        }
      }
    }
  }

  stdout.writeln('[Meetings] Pre-meeting task addition processing completed for: $taskName');
}

/// Updates newly added pre-meeting tasks with the meeting's due date if needed
///
/// [newlyAddedTaskIds] - List of task IDs that were newly added
/// [meetingDueDate] - The meeting's due date
Future<void> _updateNewlyAddedPreMeetingTasks(List<String> newlyAddedTaskIds, DateTime meetingDueDate) async {
  try {
    final updateTasks = <Future<void>>[];
    int tasksToUpdate = 0;

    for (final taskId in newlyAddedTaskIds) {
      final taskDetails = await _fetchTaskDetails(taskId);
      if (taskDetails != null) {
        final currentTaskDueDate = _parseTimestamp(taskDetails['due_date']);

        // Update if task has no due date or its due date is later than the meeting's due date
        if (currentTaskDueDate == null || meetingDueDate.isBefore(currentTaskDueDate)) {
          stdout.writeln(
              '[Meetings] Will update newly added pre-meeting task $taskId (current: $currentTaskDueDate, meeting: $meetingDueDate)');
          updateTasks.add(_updateTaskDueDate(taskId, meetingDueDate));
          tasksToUpdate++;
        } else {
          stdout.writeln(
              '[Meetings] Keeping due date for newly added pre-meeting task $taskId (current: $currentTaskDueDate, meeting: $meetingDueDate)');
        }
      } else {
        stderr.writeln('[Meetings] Failed to fetch details for newly added pre-meeting task $taskId');
      }
    }

    if (updateTasks.isNotEmpty) {
      // Execute all updates concurrently
      await Future.wait(updateTasks);
      stdout.writeln('[Meetings] Successfully updated $tasksToUpdate newly added pre-meeting tasks');
    } else {
      stdout.writeln('[Meetings] No newly added pre-meeting tasks needed updating');
    }
  } catch (e) {
    stderr.writeln('[Meetings] Error updating newly added pre-meeting tasks: $e');
  }
}

/// Conditionally updates pre-meeting tasks based on due date comparison with direct match priority
///
/// [meetingDetails] - The meeting task details (already fetched)
/// [newMeetingDueDate] - The new due date to set for qualifying pre-meeting tasks
/// [previousMeetingDueDate] - The previous due date of the meeting
Future<void> _conditionallyUpdatePreMeetingTasks(
    Map<String, dynamic> meetingDetails, DateTime? newMeetingDueDate, DateTime? previousMeetingDueDate) async {
  try {
    // Extract pre-meeting tasks from custom field
    final preMeetingTaskIds = _extractPreMeetingTaskIds(meetingDetails);

    if (preMeetingTaskIds.isEmpty) {
      stdout.writeln('[Meetings] No pre-meeting tasks found for meeting: ${meetingDetails['id']}');
      return;
    }

    stdout.writeln('[Meetings] Found ${preMeetingTaskIds.length} pre-meeting tasks to evaluate');

    // Fetch current details for each pre-meeting task and determine which ones to update
    final updateTasks = <Future<void>>[];
    int directMatchUpdates = 0;
    int conditionalUpdates = 0;

    for (final taskId in preMeetingTaskIds) {
      final taskDetails = await _fetchTaskDetails(taskId);
      if (taskDetails != null) {
        final currentTaskDueDate = _parseTimestamp(taskDetails['due_date']);

        // First Priority: Direct match with previous meeting due date
        if (_doesPreMeetingTaskMatchPreviousDueDate(currentTaskDueDate, previousMeetingDueDate)) {
          stdout.writeln(
              '[Meetings] Direct match: Will update pre-meeting task $taskId (current: $currentTaskDueDate, new: $newMeetingDueDate)');
          if (newMeetingDueDate == null) {
            updateTasks.add(_unsetTaskDueDate(taskId));
          } else {
            updateTasks.add(_updateTaskDueDate(taskId, newMeetingDueDate));
          }
          directMatchUpdates++;
        }
        // Second Priority: Conditional logic for tasks that don't match previous due date
        else if (newMeetingDueDate != null && _shouldUpdatePreMeetingTask(currentTaskDueDate, newMeetingDueDate)) {
          stdout.writeln(
              '[Meetings] Conditional: Will update pre-meeting task $taskId (current: $currentTaskDueDate, new: $newMeetingDueDate)');
          updateTasks.add(_updateTaskDueDate(taskId, newMeetingDueDate));
          conditionalUpdates++;
        } else {
          stdout.writeln(
              '[Meetings] Skipping pre-meeting task $taskId (current: $currentTaskDueDate, new: $newMeetingDueDate)');
        }
      } else {
        stderr.writeln('[Meetings] Failed to fetch details for pre-meeting task $taskId');
      }
    }

    if (updateTasks.isNotEmpty) {
      // Execute all updates concurrently
      await Future.wait(updateTasks);
      stdout.writeln(
          '[Meetings] Successfully updated $directMatchUpdates direct match tasks and $conditionalUpdates conditional tasks');
    } else {
      stdout.writeln('[Meetings] No pre-meeting tasks needed updating');
    }
  } catch (e) {
    stderr.writeln('[Meetings] Error conditionally updating pre-meeting tasks: $e');
  }
}

/// Extracts pre-meeting task IDs from the meeting task's custom field
///
/// [meetingDetails] - Complete meeting task details from ClickUp API
/// Returns a list of task IDs that are pre-meeting tasks
List<String> _extractPreMeetingTaskIds(Map<String, dynamic> meetingDetails) {
  try {
    final customFields = meetingDetails['custom_fields'] as List? ?? [];

    for (final field in customFields) {
      if (field['id'] == clickup.workspace.customFieldIds.preMeetingTasks) {
        final value = field['value'];

        if (value != null && value is List) {
          // Extract task IDs from the list
          final taskIds = <String>[];
          for (final item in value) {
            if (item is Map<String, dynamic> && item['id'] != null) {
              taskIds.add(item['id'].toString());
            }
          }
          return taskIds;
        }
      }
    }
  } catch (e) {
    stderr.writeln('[Meetings] Error extracting pre-meeting task IDs: $e');
  }

  return [];
}

/// Unsets a task's due date in ClickUp
///
/// [taskId] - The ClickUp task ID to update
Future<void> _unsetTaskDueDate(String taskId) async {
  try {
    // Make the API call to unset the task's due date
    final response = await http.put(
      Uri.parse('${clickup.API_BASE_URL}/task/$taskId'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'due_date': null,
      }),
    );

    if (response.statusCode == 200) {
      stdout.writeln('[Meetings] Successfully unset due date for pre-meeting task $taskId');
    } else {
      stderr.writeln(
          '[Meetings] Failed to unset due date for pre-meeting task $taskId. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[Meetings] Error unsetting due date for pre-meeting task $taskId: $e');
  }
}

/// Updates a task's due date in ClickUp
///
/// [taskId] - The ClickUp task ID to update
/// [dueDate] - The new due date to set
Future<void> _updateTaskDueDate(String taskId, DateTime dueDate) async {
  try {
    // Make the API call to update the task's due date
    final response = await http.put(
      Uri.parse('${clickup.API_BASE_URL}/task/$taskId'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'due_date': dueDate.millisecondsSinceEpoch,
      }),
    );

    if (response.statusCode == 200) {
      stdout.writeln('[Meetings] Successfully updated due date for pre-meeting task $taskId to $dueDate');
    } else {
      stderr.writeln(
          '[Meetings] Failed to update due date for pre-meeting task $taskId. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[Meetings] Error updating due date for pre-meeting task $taskId: $e');
  }
}

/// Fetches task details for a given task ID
///
/// [taskId] - The ClickUp task ID
/// Returns task details or null if fetch fails
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
      final taskData = jsonDecode(response.body);
      return taskData;
    } else {
      stderr.writeln('[Meetings] Failed to fetch task details for $taskId: ${response.statusCode} - ${response.body}');
      return null;
    }
  } catch (e) {
    stderr.writeln('[Meetings] Error fetching task details for $taskId: $e');
    return null;
  }
}

/// Checks if a pre-meeting task should be updated based on due date comparison
///
/// [preMeetingTaskDueDate] - Current due date of the pre-meeting task (can be null)
/// [newMeetingDueDate] - New due date of the meeting
/// Returns true if the pre-meeting task should be updated
bool _shouldUpdatePreMeetingTask(DateTime? preMeetingTaskDueDate, DateTime? newMeetingDueDate) {
  // If new meeting due date is null, we shouldn't update here (handled separately)
  if (newMeetingDueDate == null) return false;

  // If pre-meeting task has no due date, always update
  if (preMeetingTaskDueDate == null) return true;

  // If new meeting due date is earlier than pre-meeting task due date, update
  return newMeetingDueDate.isBefore(preMeetingTaskDueDate);
}

/// Checks if a pre-meeting task's due date matches the previous meeting due date
///
/// [preMeetingTaskDueDate] - Current due date of the pre-meeting task (can be null)
/// [previousMeetingDueDate] - Previous due date of the meeting (can be null)
/// Returns true if the due dates match exactly (including time)
bool _doesPreMeetingTaskMatchPreviousDueDate(DateTime? preMeetingTaskDueDate, DateTime? previousMeetingDueDate) {
  // Both null - they match
  if (preMeetingTaskDueDate == null && previousMeetingDueDate == null) return true;

  // One null, one not - they don't match
  if (preMeetingTaskDueDate == null || previousMeetingDueDate == null) return false;

  // Compare the entire DateTime including time components
  return preMeetingTaskDueDate.isAtSameMomentAs(previousMeetingDueDate);
}

/// Converts a timestamp string to a DateTime object
///
/// [timestamp] - Timestamp string in milliseconds
/// Returns DateTime object or null if timestamp is null, or DateTime.now() if parsing fails
DateTime? _parseTimestamp(dynamic timestamp) {
  if (timestamp == null) return null;

  try {
    final milliseconds = int.parse(timestamp.toString());
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  } catch (e) {
    stdout.writeln('[Meetings] Warning: Could not parse timestamp: $timestamp, using current time');
    return DateTime.now();
  }
}
