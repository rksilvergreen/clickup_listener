import 'dart:io';

import 'package:timezone/timezone.dart' as tz;

import '../env/clickup.dart' as clickup;
import 'dart:convert'; // Added for jsonEncode
import 'package:http/http.dart' as http; // Added for http

/// Checks if a task is of type "event"
///
/// [taskDetails] - Complete task details from ClickUp API
/// Returns true if the task is an event, false otherwise
bool isEventTask(Map<String, dynamic> taskDetails) {
  // Check if the task's custom_item_id matches the event task type ID
  final customItemId = taskDetails['custom_item_id']?.toString();
  return customItemId == clickup.workspace.taskTypeIds.event;
}

/// Checks if a newly created event task has relevant fields set
///
/// [taskDetails] - Complete task details from ClickUp API
/// Returns true if the task is an event and has start date, due date, relevance num, or relevance unit set
bool isRelevantEventCreate(Map<String, dynamic> taskDetails) {
  // First check if this is an event task
  if (!isEventTask(taskDetails)) {
    return false;
  }

  // Check if any relevant fields are set
  final hasStartDate = taskDetails['start_date'] != null;
  final hasDueDate = taskDetails['due_date'] != null;

  // Check if relevance fields have values
  final customFields = taskDetails['custom_fields'] as List? ?? [];
  bool hasRelevanceNum = false;
  bool hasRelevanceUnit = false;

  for (final field in customFields) {
    if (field['id'] == clickup.workspace.customFieldIds.relevanceNum && field['value'] != null) {
      hasRelevanceNum = true;
    }
    if (field['id'] == clickup.workspace.customFieldIds.relevanceUnit && field['value'] != null) {
      hasRelevanceUnit = true;
    }
  }

  // Return true if any relevant field is set
  return hasStartDate || hasDueDate || hasRelevanceNum || hasRelevanceUnit;
}

/// Checks if an event update is relevant (involves changes to important fields)
///
/// [taskDetails] - Complete task details from ClickUp API
/// [webhookBody] - Original webhook payload for context
/// Returns true if the update involves changes to Start date, Due date, Relevance num, or Relevance Unit
bool isRelevantEventUpdate(Map<String, dynamic> taskDetails, Map<String, dynamic> webhookBody) {
  // First check if this is an event task
  if (!isEventTask(taskDetails)) {
    return false;
  }

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

    // Check for custom field changes (relevance fields)
    if (field == 'custom_field') {
      final customField = item['custom_field'] as Map<String, dynamic>?;
      if (customField != null) {
        final customFieldId = customField['id'] as String?;

        // Check if this is a relevance field change
        if (customFieldId == clickup.workspace.customFieldIds.relevanceNum ||
            customFieldId == clickup.workspace.customFieldIds.relevanceUnit) {
          return true;
        }
      }
    }
  }

  return false;
}

// -------- Event handling functions --------

/// Handles when a new event task is created
///
/// This function initializes all relevant custom fields for a newly created event task,
/// including start time, end time, status, and relevance date based on the task's dates.
///
/// [taskDetails] - Complete task details from ClickUp API
Future<void> onEventCreated(Map<String, dynamic> taskDetails) async {
  final taskId = taskDetails['id'];
  final taskName = taskDetails['name'];

  stdout.writeln('[Events] Processing new event creation for: $taskName (ID: $taskId)');

  // Get current dates from task details and convert to DateTime
  final startDate = _parseTimestamp(taskDetails['start_date']);
  final dueDate = _parseTimestamp(taskDetails['due_date']);
  final (relevanceNum, relevanceUnit) = _parseRelevanceValues(taskDetails);

  stdout.writeln('[Events] Initial dates - Start: $startDate, Due: $dueDate');
  stdout.writeln('[Events] Initial relevance values - Num: $relevanceNum, Unit: ${relevanceUnit?.toDisplayString()}');

  // Calculate all the required values
  final startTime = calculateStartTime(startDate, dueDate);
  final endTime = calculateEndTime(dueDate);
  final status = calculateStatus(startTime, endTime);
  final relevanceDate = calculateRelevanceDate(startTime, endTime, relevanceNum, relevanceUnit);

  stdout.writeln(
      '[Events] Calculated values - StartTime: $startTime, EndTime: $endTime, Status: $status, RelevanceDate: $relevanceDate');

  // Set all custom fields concurrently
  final tasks = <Future<void>>[];

  // Always set start time if we have one
  if (startTime != null) {
    tasks.add(setStartTime(taskId, startTime));
  }

  // Always set end time if we have one
  if (endTime != null) {
    tasks.add(setEndTime(taskId, endTime));
  }

  // Always set status
  tasks.add(setStatus(taskId, status));

  // Set relevance date if we calculated one
  if (relevanceDate != null) {
    tasks.add(setRelevanceDate(taskId, relevanceDate));
  }

  // Execute all updates concurrently
  await Future.wait(tasks);

  stdout.writeln('[Events] Event creation processing completed for: $taskName');
}

/// Handles updates to ClickUp tasks of type "event"
///
/// This function checks if the start date, due date, or relevance fields have changed and
/// invokes the appropriate handler function.
///
/// [taskDetails] - Complete task details from ClickUp API
/// [webhookBody] - Original webhook payload for context
Future<void> onEventUpdated(Map<String, dynamic> taskDetails, Map<String, dynamic> webhookBody) async {
  final taskId = taskDetails['id'];
  final taskName = taskDetails['name'];

  stdout.writeln('[Events] Processing event update for: $taskName (ID: $taskId)');

  // Get current dates from task details and convert to DateTime
  final startDate = _parseTimestamp(taskDetails['start_date']);
  final dueDate = _parseTimestamp(taskDetails['due_date']);
  final (relevanceNum, relevanceUnit) = _parseRelevanceValues(taskDetails);

  // Check what changed in the webhook
  final historyItems = webhookBody['history_items'] as List? ?? [];

  for (final item in historyItems) {
    final field = item['field'];
    final before = item['before'];
    final after = item['after'];

    if (field == 'start_date') {
      stdout.writeln('[Events] Start date changed from $before to $after');
      await onStartDateChanged(taskId, startDate, dueDate, relevanceNum, relevanceUnit);
    } else if (field == 'due_date') {
      stdout.writeln('[Events] Due date changed from $before to $after');
      await onDueDateChanged(taskId, startDate, dueDate, relevanceNum, relevanceUnit);
    } else if (field == 'custom_field') {
      // Check if this is a relevance field change
      final customField = item['custom_field'] as Map<String, dynamic>?;
      if (customField != null) {
        final customFieldId = customField['id'] as String?;

        if (customFieldId == clickup.workspace.customFieldIds.relevanceNum) {
          stdout.writeln('[Events] Relevance number changed from $before to $after');
          await onRelevanceNumChanged(taskId, startDate, dueDate, relevanceNum, relevanceUnit);
        } else if (customFieldId == clickup.workspace.customFieldIds.relevanceUnit) {
          stdout.writeln('[Events] Relevance unit changed from $before to $after');
          await onRelevanceUnitChanged(taskId, startDate, dueDate, relevanceNum, relevanceUnit);
        }
      }
    }
  }

  stdout.writeln('[Events] Event update processing completed for: $taskName');
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
    stdout.writeln('[Events] Warning: Could not parse timestamp: $timestamp, using current time');
    return DateTime.now();
  }
}

/// Extracts relevance values from task details
/// Returns a tuple of (relevanceNum, relevanceUnit) or (null, null) if not found
(int?, RelevanceUnit?) _parseRelevanceValues(Map<String, dynamic> taskDetails) {
  try {
    final relevanceNumField = taskDetails['custom_fields']?.firstWhere(
      (field) => field['id'] == clickup.workspace.customFieldIds.relevanceNum,
      orElse: () => null,
    );

    final relevanceUnitField = taskDetails['custom_fields']?.firstWhere(
      (field) => field['id'] == clickup.workspace.customFieldIds.relevanceUnit,
      orElse: () => null,
    );

    if (relevanceNumField != null && relevanceUnitField != null) {
      // Parse the relevance number from string to int
      final relevanceNumStr = relevanceNumField['value'] as String?;
      final relevanceNum = relevanceNumStr != null ? int.tryParse(relevanceNumStr) : null;

      // Parse the relevance unit from numeric index to enum
      final relevanceUnitIndex = relevanceUnitField['value'] as int?;
      RelevanceUnit? relevanceUnit;

      if (relevanceUnitIndex != null) {
        try {
          relevanceUnit = RelevanceUnit.values[relevanceUnitIndex];
        } catch (e) {
          stdout.writeln('[Events] Warning: Invalid relevance unit index: $relevanceUnitIndex, Error: $e');
        }
      }

      return (relevanceNum, relevanceUnit);
    }
  } catch (e) {
    stdout.writeln('[Events] Error extracting relevance values: $e');
  }

  return (null, null);
}

/// Handles when the start date of an event task changes
///
/// [taskId] - The ClickUp task ID
/// [startDate] - The new start date
/// [dueDate] - The current due date
/// [relevanceNum] - The relevance number value
/// [relevanceUnit] - The relevance unit value
Future<void> onStartDateChanged(
    String taskId, DateTime? startDate, DateTime? dueDate, int? relevanceNum, RelevanceUnit? relevanceUnit) async {
  stdout.writeln('[Events] Start date changed handler - Start: $startDate, Due: $dueDate');
  stdout.writeln('[Events] Relevance values - Num: $relevanceNum, Unit: ${relevanceUnit?.toDisplayString()}');

  // Calculate both start and end times using separate helper functions
  final startTime = calculateStartTime(startDate, dueDate);
  final endTime = calculateEndTime(dueDate);
  final status = calculateStatus(startTime, endTime);

  // Calculate relevance date based on start/end times and relevance values
  final relevanceDate = calculateRelevanceDate(startTime, endTime, relevanceNum, relevanceUnit);

  // Update the ClickUp task with calculated times, status, and relevance date
  await Future.wait([
    setStartTime(taskId, startTime),
    setStatus(taskId, status),
    setRelevanceDate(taskId, relevanceDate),
  ]);
}

/// Handles when the due date of an event task changes
///
/// [taskId] - The ClickUp task ID
/// [startDate] - The current start date
/// [dueDate] - The new due date
/// [relevanceNum] - The relevance number value
/// [relevanceUnit] - The relevance unit value
Future<void> onDueDateChanged(
    String taskId, DateTime? startDate, DateTime? dueDate, int? relevanceNum, RelevanceUnit? relevanceUnit) async {
  stdout.writeln('[Events] Due date changed handler - Start: $startDate, Due: $dueDate');
  stdout.writeln('[Events] Relevance values - Num: $relevanceNum, Unit: ${relevanceUnit?.toDisplayString()}');

  // Calculate both start and end times using separate helper functions
  final startTime = calculateStartTime(startDate, dueDate);
  final endTime = calculateEndTime(dueDate);
  final status = calculateStatus(startTime, endTime);

  // Calculate relevance date based on start/end times and relevance values
  final relevanceDate = calculateRelevanceDate(startTime, endTime, relevanceNum, relevanceUnit);

  // Update the ClickUp task with calculated times, status, and relevance date
  await Future.wait([
    if (startDate == null) setStartTime(taskId, startTime),
    setEndTime(taskId, endTime),
    setStatus(taskId, status),
    setRelevanceDate(taskId, relevanceDate),
  ]);
}

/// Handles when the relevance number of an event task changes
///
/// [taskId] - The ClickUp task ID
/// [startDate] - The current start date
/// [dueDate] - The current due date
/// [relevanceNum] - The new relevance number value
/// [relevanceUnit] - The current relevance unit value
Future<void> onRelevanceNumChanged(
    String taskId, DateTime? startDate, DateTime? dueDate, int? relevanceNum, RelevanceUnit? relevanceUnit) async {
  stdout.writeln(
      '[Events] Relevance number changed handler - Num: $relevanceNum, Unit: ${relevanceUnit?.toDisplayString()}');

  // Calculate both start and end times using separate helper functions
  final startTime = calculateStartTime(startDate, dueDate);
  final endTime = calculateEndTime(dueDate);

  // Calculate relevance date based on start/end times and relevance values
  final relevanceDate = calculateRelevanceDate(startTime, endTime, relevanceNum, relevanceUnit);

  // Update the ClickUp task with calculated status and relevance date
  await Future.wait([
    setRelevanceDate(taskId, relevanceDate),
  ]);
}

/// Handles when the relevance unit of an event task changes
///
/// [taskId] - The ClickUp task ID
/// [startDate] - The current start date
/// [dueDate] - The current due date
/// [relevanceNum] - The current relevance number value
/// [relevanceUnit] - The new relevance unit value
Future<void> onRelevanceUnitChanged(
    String taskId, DateTime? startDate, DateTime? dueDate, int? relevanceNum, RelevanceUnit? relevanceUnit) async {
  stdout.writeln(
      '[Events] Relevance unit changed handler - Num: $relevanceNum, Unit: ${relevanceUnit?.toDisplayString()}');

  // Calculate both start and end times using separate helper functions
  final startTime = calculateStartTime(startDate, dueDate);
  final endTime = calculateEndTime(dueDate);
  final status = calculateStatus(startTime, endTime);

  // Calculate relevance date based on start/end times and relevance values
  final relevanceDate = calculateRelevanceDate(startTime, endTime, relevanceNum, relevanceUnit);

  // Update the ClickUp task with calculated status and relevance date
  await Future.wait([
    setStatus(taskId, status),
    setRelevanceDate(taskId, relevanceDate),
  ]);
}

/// Calculates the start time for an event based on start and due dates
///
/// [startDate] - The start date of the event, can be null
/// [dueDate] - The due date of the event, can be null
/// Returns the calculated start time with proper adjustments
DateTime? calculateStartTime(DateTime? startDate, DateTime? dueDate) {
  if (startDate != null) {
    if (isTimeSpecified(startDate)) {
      // Start date has a specific time, use it as is
      final startTime = startDate;
      stdout.writeln('[Events] Start date has specific time, setting start time to: $startTime');
      return startTime;
    } else {
      // Start date doesn't have specific time, adjust to 00:00 of the same day
      final startTime = adjustNonTimeSpecifiedStartDate(startDate);
      stdout.writeln('[Events] Start date has no specific time, adjusting to: $startTime');
      return startTime;
    }
  } else {
    // Start date is null
    if (dueDate != null && !isTimeSpecified(dueDate)) {
      // Due date is not time specified, set start time to 00:00 of the due date
      final startTime = adjustNonTimeSpecifiedStartDate(dueDate);
      stdout.writeln('[Events] Start date is null, due date has no specific time, setting start time to: $startTime');
      return startTime;
    } else {
      // Start date is null and due date is either null or time-specified, set start time to null
      stdout.writeln(
          '[Events] Start date is null and due date is either null or time-specified, setting start time to null');
      return null;
    }
  }
}

/// Calculates the end time for an event based on due date
///
/// [dueDate] - The due date of the event, can be null
/// Returns the calculated end time with proper adjustments
DateTime? calculateEndTime(DateTime? dueDate) {
  if (dueDate != null) {
    if (isTimeSpecified(dueDate)) {
      // Due date has a specific time, use it as is
      final endTime = dueDate;
      stdout.writeln('[Events] Due date has specific time, setting end time to: $endTime');
      return endTime;
    } else {
      // Due date doesn't have specific time, adjust to 00:00 of the next day
      final endTime = adjustNonTimeSpecifiedDueDate(dueDate);
      stdout.writeln('[Events] Due date has no specific time, adjusting to: $endTime');
      return endTime;
    }
  } else {
    // Due date is null, set end time to null
    stdout.writeln('[Events] Due date is null, setting end time to null');
    return null;
  }
}

/// Checks if a DateTime has a specific time other than 4:00 AM in Asia/Jerusalem timezone
///
/// [dateTime] - The DateTime to check
/// Returns true if the time is specified (not 4:00 AM), false otherwise
bool isTimeSpecified(DateTime dateTime) {
  // Convert to Asia/Jerusalem timezone
  final jerusalemLocation = tz.getLocation('Asia/Jerusalem');
  final jerusalemTime = tz.TZDateTime.from(dateTime, jerusalemLocation);

  // Check if the time is 4:00 AM
  return !(jerusalemTime.hour == 4 && jerusalemTime.minute == 0);
}

/// Adjusts a DateTime to 00:00 (midnight) of the same day
///
/// [dateTime] - The DateTime to adjust
/// Returns a new DateTime set to 00:00:00.000 of the same day
DateTime adjustNonTimeSpecifiedStartDate(DateTime dateTime) {
  return DateTime(dateTime.year, dateTime.month, dateTime.day);
}

/// Adjusts a DateTime to 00:00 (midnight) of the next day
///
/// [dateTime] - The DateTime to adjust
/// Returns a new DateTime set to 00:00:00.000 of the next day
DateTime adjustNonTimeSpecifiedDueDate(DateTime dateTime) {
  return DateTime(dateTime.year, dateTime.month, dateTime.day + 1);
}

// -------- Event Status Enum --------
enum EventStatus {
  NOT_SCHEDULED,
  UPCOMING,
  OCCURRING,
  OCCURRED;

  static final Map<EventStatus, String> _map = {
    EventStatus.NOT_SCHEDULED: 'not scheduled',
    EventStatus.UPCOMING: 'upcoming',
    EventStatus.OCCURRING: 'occurring',
    EventStatus.OCCURRED: 'occurred',
  };

  static EventStatus fromString(String value) {
    final entry = _map.entries.firstWhere(
      (entry) => entry.value == value,
      orElse: () => throw ArgumentError('Invalid event status: $value'),
    );
    return entry.key;
  }

  String toDisplayString() {
    return name[0] + name.substring(1).toLowerCase();
  }

  @override
  String toString() => _map[this]!;
}

/// Calculates the current status of an event based on start and end times
///
/// [startTime] - The start time of the event, can be null
/// [endTime] - The end time of the event, can be null
/// Returns the current EventStatus of the event
EventStatus calculateStatus(DateTime? startTime, DateTime? endTime) {
  final now = DateTime.now();

  if (startTime == null && endTime == null) {
    return EventStatus.NOT_SCHEDULED;
  } else if (startTime == null) {
    // Only end time
    return (now.isAfter(endTime!) || now.isAtSameMomentAs(endTime)) ? EventStatus.OCCURRED : EventStatus.UPCOMING;
  } else if (endTime == null) {
    // Only start time
    return (now.isAfter(startTime) || now.isAtSameMomentAs(startTime)) ? EventStatus.OCCURRING : EventStatus.UPCOMING;
  } else {
    // Both start and end
    if (now.isAfter(endTime) || now.isAtSameMomentAs(endTime)) {
      return EventStatus.OCCURRED;
    } else if (now.isAfter(startTime) || now.isAtSameMomentAs(startTime)) {
      return EventStatus.OCCURRING;
    } else {
      return EventStatus.UPCOMING;
    }
  }
}

// -------- Relevance Unit Enum --------
enum RelevanceUnit {
  DAYS,
  WEEKS,
  MONTHS;

  static final Map<RelevanceUnit, String> _map = {
    RelevanceUnit.DAYS: 'days',
    RelevanceUnit.WEEKS: 'weeks',
    RelevanceUnit.MONTHS: 'months',
  };

  static RelevanceUnit fromString(String value) {
    final entry = _map.entries.firstWhere(
      (entry) => entry.value == value,
      orElse: () => throw ArgumentError('Invalid relevance unit: $value'),
    );
    return entry.key;
  }

  String toDisplayString() {
    return name[0] + name.substring(1).toLowerCase();
  }

  @override
  String toString() => _map[this]!;
}

/// Calculates the relevance date based on start/end times and relevance interval
///
/// [startTime] - The start time of the event, can be null
/// [endTime] - The end time of the event, can be null
/// [relevanceNum] - The relevance number value
/// [relevanceUnit] - The relevance unit value
/// Returns a DateTime representing the relevance date, or null if both start and end times are null
DateTime? calculateRelevanceDate(
    DateTime? startTime, DateTime? endTime, int? relevanceNum, RelevanceUnit? relevanceUnit) {
  // If both start and end times are null, return null
  if (startTime == null && endTime == null) {
    return null;
  }

  // If relevance values are not provided, return null
  if (relevanceNum == null || relevanceUnit == null) {
    return null;
  }

  // Calculate the relevance interval duration
  Duration relevanceInterval;
  switch (relevanceUnit) {
    case RelevanceUnit.DAYS:
      relevanceInterval = Duration(days: relevanceNum);
      break;
    case RelevanceUnit.WEEKS:
      relevanceInterval = Duration(days: relevanceNum * 7);
      break;
    case RelevanceUnit.MONTHS:
      // Approximate months as 30 days for simplicity
      relevanceInterval = Duration(days: relevanceNum * 30);
      break;
  }

  // If start time is not null, subtract relevance interval from start time
  if (startTime != null) {
    return startTime.subtract(relevanceInterval);
  }

  // If start time is null but end time is not, subtract relevance interval from end time
  if (endTime != null) {
    return endTime.subtract(relevanceInterval);
  }

  return null;
}

/// Updates the "Start Time" custom field in ClickUp for a given task
///
/// [taskId] - The ClickUp task ID
/// [startTime] - The DateTime to set as the start time, or null to clear the field
Future<void> setStartTime(String taskId, DateTime? startTime) async {
  try {
    // Prepare the request body
    final requestBody = {
      "value_options": {"time": true},
      "value": startTime?.millisecondsSinceEpoch
    };

    // Make the API call to update the custom field
    final response = await http.post(
      Uri.parse('${clickup.API_BASE_URL}/task/$taskId/field/${clickup.workspace.customFieldIds.startTime}'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      if (startTime != null) {
        stdout.writeln('[Events] Successfully updated Start Time for task $taskId to $startTime');
      } else {
        stdout.writeln('[Events] Successfully cleared Start Time for task $taskId');
      }
    } else {
      stderr.writeln(
          '[Events] Failed to update Start Time for task $taskId. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[Events] Error updating Start Time for task $taskId: $e');
  }
}

/// Updates the "End Time" custom field in ClickUp for a given task
///
/// [taskId] - The ClickUp task ID
/// [endTime] - The DateTime to set as the end time, or null to clear the field
Future<void> setEndTime(String taskId, DateTime? endTime) async {
  try {
    // Prepare the request body
    final requestBody = {
      "value_options": {"time": true},
      "value": endTime?.millisecondsSinceEpoch
    };

    // Make the API call to update the custom field
    final response = await http.post(
      Uri.parse('${clickup.API_BASE_URL}/task/$taskId/field/${clickup.workspace.customFieldIds.endTime}'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      if (endTime != null) {
        stdout.writeln('[Events] Successfully updated End Time for task $taskId to $endTime');
      } else {
        stdout.writeln('[Events] Successfully cleared End Time for task $taskId');
      }
    } else {
      stderr.writeln(
          '[Events] Failed to update End Time for task $taskId. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[Events] Error updating End Time for task $taskId: $e');
  }
}

/// Updates the "Relevance Date" custom field in ClickUp for a given task
///
/// [taskId] - The ClickUp task ID
/// [relevanceDate] - The DateTime to set as the relevance date, or null to clear the field
Future<void> setRelevanceDate(String taskId, DateTime? relevanceDate) async {
  try {
    // Prepare the request body
    final requestBody = {
      "value_options": {"time": true},
      "value": relevanceDate?.millisecondsSinceEpoch
    };

    // Make the API call to update the custom field
    final response = await http.post(
      Uri.parse('${clickup.API_BASE_URL}/task/$taskId/field/${clickup.workspace.customFieldIds.relevanceDate}'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      if (relevanceDate != null) {
        stdout.writeln('[Events] Successfully updated Relevance Date for task $taskId to $relevanceDate');
      } else {
        stdout.writeln('[Events] Successfully cleared Relevance Date for task $taskId');
      }
    } else {
      stderr.writeln(
          '[Events] Failed to update Relevance Date for task $taskId. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[Events] Error updating Relevance Date for task $taskId: $e');
  }
}

/// Updates the ClickUp task status
///
/// [taskId] - The ClickUp task ID to update
/// [status] - The EventStatus to set
Future<void> setStatus(String taskId, EventStatus status) async {
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
      stdout.writeln('[Events] Successfully updated status for task $taskId to: ${status.toString()}');
    } else {
      stderr.writeln(
          '[Events] Failed to update status for task $taskId. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[Events] Error updating status for task $taskId: $e');
  }
}
