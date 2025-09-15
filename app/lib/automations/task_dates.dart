import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../env/clickup.dart' as clickup;

// -------- Task Status Enum --------
enum TaskStatus {
  BACKLOG,
  TO_DO,
  IN_PROGRESS,
  COMPLETE;

  static final Map<TaskStatus, String> _map = {
    TaskStatus.BACKLOG: 'backlog',
    TaskStatus.TO_DO: 'to do',
    TaskStatus.IN_PROGRESS: 'in progress',
    TaskStatus.COMPLETE: 'complete',
  };

  static TaskStatus fromString(String value) {
    final entry = _map.entries.firstWhere(
      (entry) => entry.value == value,
      orElse: () => throw ArgumentError('Invalid task status: $value'),
    );
    return entry.key;
  }

  String toDisplayString() {
    return name[0] + name.substring(1).toLowerCase();
  }

  @override
  String toString() => _map[this]!;
}

/// Checks if a newly created task has relevant date fields set
///
/// [taskDetails] - Complete task details from ClickUp API
/// Returns true if the task has start date or due date set
bool isRelevantDatesCreate(Map<String, dynamic> taskDetails) {
  return true;
}

/// Checks if a task update involves changes to relevant date fields
///
/// [webhookBody] - Original webhook payload for context
/// Returns true if the update involves changes to start date or due date
bool isRelevantDatesUpdate(Map<String, dynamic> webhookBody) {
  // Check if there are any history items
  final historyItems = webhookBody['history_items'] as List? ?? [];
  if (historyItems.isEmpty) {
    return false;
  }

  // Check each history item for relevant field changes
  for (final item in historyItems) {
    final field = item['field'];

    // Check for date field changes
    if (field == 'start_date' || field == 'due_date') {
      return true;
    }
  }

  return false;
}

/// Handles when the start date of a task changes
///
/// [taskId] - The ClickUp task ID
/// [startDate] - The new start date
/// [dueDate] - The current due date
/// [previousStatus] - The previous status of the task
Future<void> onStartDateChanged(
    String taskId, DateTime? startDate, DateTime? dueDate, TaskStatus? previousStatus) async {
  stdout.writeln('[TaskDates] Start date changed handler - Start: $startDate, Due: $dueDate');

  // Calculate the new task status based on start and due dates and previous status
  final status = calculateTaskStatus(startDate, dueDate, previousStatus);

  // Update the ClickUp task status
  await setTaskStatus(taskId, status);
}

/// Handles when the due date of a task changes
///
/// [taskId] - The ClickUp task ID
/// [startDate] - The current start date
/// [dueDate] - The new due date
/// [previousStatus] - The previous status of the task
Future<void> onDueDateChanged(String taskId, DateTime? startDate, DateTime? dueDate, TaskStatus? previousStatus) async {
  stdout.writeln('[TaskDates] Due date changed handler - Start: $startDate, Due: $dueDate');

  // Calculate the new task status based on start and due dates and previous status
  final status = calculateTaskStatus(startDate, dueDate, previousStatus);

  // Update the ClickUp task status
  await setTaskStatus(taskId, status);
}

/// Calculates the current status of a task based on start and due dates and previous status
///
/// [startDate] - The start date of the task, can be null
/// [dueDate] - The due date of the task, can be null
/// [previousStatus] - The previous status of the task, can be null
/// Returns the current TaskStatus of the task
TaskStatus calculateTaskStatus(DateTime? startDate, DateTime? dueDate, [TaskStatus? previousStatus]) {
  final hasStartDate = startDate != null;
  final hasDueDate = dueDate != null;
  final hasAnyDate = hasStartDate || hasDueDate;
  final hasNoDates = !hasStartDate && !hasDueDate;

  // If start date and/or due date are set, and the previous status was BACKLOG, then set status to TO DO
  if (hasAnyDate && previousStatus == TaskStatus.BACKLOG) {
    return TaskStatus.TO_DO;
  }

  // If start date and due date switched to null, and now both dates are null, and the previous status was not BACKLOG, then switch status to BACKLOG
  if (hasNoDates && previousStatus != null && previousStatus != TaskStatus.BACKLOG) {
    return TaskStatus.BACKLOG;
  }

  return previousStatus!;
}

/// Updates the ClickUp task status
///
/// [taskId] - The ClickUp task ID to update
/// [status] - The TaskStatus to set
Future<void> setTaskStatus(String taskId, TaskStatus status) async {
  try {
    // Make the API call to update the task status
    final response = await http.put(
      Uri.parse('${clickup.API_BASE_URL}/task/$taskId'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'status': status.toString(),
      }),
    );

    if (response.statusCode == 200) {
      stdout.writeln('[TaskDates] Successfully updated status for task $taskId to: ${status.toString()}');
    } else {
      stderr.writeln(
          '[TaskDates] Failed to update status for task $taskId. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[TaskDates] Error updating status for task $taskId: $e');
  }
}

/// Handles when a new task is created
///
/// This function processes newly created tasks and sets their initial status
/// based on start and due dates if they are set.
///
/// [taskDetails] - Complete task details from ClickUp API
Future<void> onTaskCreated(Map<String, dynamic> taskDetails) async {
  final taskId = taskDetails['id'];
  final taskName = taskDetails['name'];

  stdout.writeln('[TaskDates] Processing new task creation for: $taskName (ID: $taskId)');

  // Get current dates from task details and convert to DateTime
  final startDate = _parseTimestamp(taskDetails['start_date']);
  final dueDate = _parseTimestamp(taskDetails['due_date']);

  stdout.writeln('[TaskDates] Initial dates - Start: $startDate, Due: $dueDate');

  // Get the previous status from task details
  final previousStatus = _parseTaskStatus(taskDetails['status']?['status']);

  // For new tasks, there's no previous status, so we pass null
  final status = calculateTaskStatus(startDate, dueDate, previousStatus);

  stdout.writeln('[TaskDates] Calculated initial status: $status');

  // Update the ClickUp task status
  await setTaskStatus(taskId, status);

  stdout.writeln('[TaskDates] Task creation processing completed for: $taskName');
}

/// Handles updates to ClickUp tasks
///
/// This function checks if the start date or due date have changed and
/// invokes the appropriate handler function to update the task status.
///
/// [taskDetails] - Complete task details from ClickUp API
/// [webhookBody] - Original webhook payload for context
Future<void> onTaskUpdated(Map<String, dynamic> taskDetails, Map<String, dynamic> webhookBody) async {
  final taskId = taskDetails['id'];
  final taskName = taskDetails['name'];

  stdout.writeln('[TaskDates] Processing task update for: $taskName (ID: $taskId)');

  // Get current dates from task details and convert to DateTime
  final startDate = _parseTimestamp(taskDetails['start_date']);
  final dueDate = _parseTimestamp(taskDetails['due_date']);

  // Check what changed in the webhook
  final historyItems = webhookBody['history_items'] as List? ?? [];

  for (final item in historyItems) {
    final field = item['field'];
    final before = item['before'];
    final after = item['after'];

    final previousStatus = _parseTaskStatus(taskDetails['status']?['status']);

    if (field == 'start_date') {
      stdout.writeln('[TaskDates] Start date changed from $before to $after');
      await onStartDateChanged(taskId, startDate, dueDate, previousStatus);
    } else if (field == 'due_date') {
      stdout.writeln('[TaskDates] Due date changed from $before to $after');
      await onDueDateChanged(taskId, startDate, dueDate, previousStatus);
    }
  }

  stdout.writeln('[TaskDates] Task update processing completed for: $taskName');
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
    stdout.writeln('[TaskDates] Warning: Could not parse timestamp: $timestamp, using current time');
    return DateTime.now();
  }
}

/// Parses a task status string to TaskStatus enum
///
/// [statusString] - The status string from ClickUp API
/// Returns the corresponding TaskStatus enum value, or null if parsing fails
TaskStatus? _parseTaskStatus(String? statusString) {
  if (statusString == null) return null;
  try {
    return TaskStatus.fromString(statusString);
  } catch (e) {
    stdout.writeln('[TaskDates] Warning: Could not parse status string: $statusString, Error: $e');
    return null;
  }
}
