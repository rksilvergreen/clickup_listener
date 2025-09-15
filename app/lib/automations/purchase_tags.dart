import 'dart:io';
import 'package:http/http.dart' as http;
import '../env/clickup.dart' as clickup;

/// Checks if the added tag is a relevant purchase tag
///
/// [tagDetails] - Details of the tag that was added
/// Returns true if the tag name matches the purchase tag name
bool isRelevantPurchaseTagAdded(Map<String, dynamic> tagDetails) {
  final tagName = tagDetails['name'] as String?;
  return tagName != null && tagName == clickup.workspace.tagNames.purchase;
}

/// Checks if the removed tag is a relevant purchase tag
///
/// [tagDetails] - Details of the tag that was removed
/// Returns true if the tag name matches the purchase tag name
bool isRelevantPurchaseTagRemoved(Map<String, dynamic> tagDetails) {
  final tagName = tagDetails['name'] as String?;
  return tagName != null && tagName == clickup.workspace.tagNames.purchase;
}

/// Handles when a purchase tag is added to a task
///
/// [taskDetails] - Complete task details from ClickUp API
/// [tagDetails] - Details of the tag that was added
Future<void> onPurchaseTagAdded(Map<String, dynamic> taskDetails, Map<String, dynamic> tagDetails) async {
  final taskId = taskDetails['id'];
  final tagName = tagDetails['name'];
  stdout.writeln('[Tags] Purchase tag "$tagName" added to task: $taskId');

  // Check if task is already in shopping list
  if (!isShoppingTask(taskDetails)) {
    // Add task to shopping list
    await moveToShoppingList(taskId, taskDetails);
    stdout.writeln('[Tags] Added task $taskId to shopping list');
  } else {
    stdout.writeln('[Tags] Task $taskId is already in shopping list');
  }
}

/// Handles when a purchase tag is removed from a task
///
/// [taskDetails] - Complete task details from ClickUp API
/// [tagDetails] - Details of the tag that was removed
Future<void> onPurchaseTagRemoved(Map<String, dynamic> taskDetails, Map<String, dynamic> tagDetails) async {
  final taskId = taskDetails['id'];
  final tagName = tagDetails['name'];
  stdout.writeln('[Tags] Purchase tag "$tagName" removed from task: $taskId');

  // Check if task is in shopping list
  if (isShoppingTask(taskDetails)) {
    // Remove task from shopping list
    await removeFromShoppingList(taskId, taskDetails);
    stdout.writeln('[Tags] Removed task $taskId from shopping list');
  } else {
    stdout.writeln('[Tags] Task $taskId is not in shopping list');
  }
}

/// Checks if a task is in the shopping list
///
/// [taskDetails] - Complete task details from ClickUp API
/// Returns true if the task is in the shopping list
bool isShoppingTask(Map<String, dynamic> taskDetails) {
  // Check if the task's list ID matches the shopping list ID
  final taskListId = taskDetails['list']?['id']?.toString();
  if (taskListId == clickup.workspace.listIds.shopping) {
    return true;
  }

  // Also check if the task's location ID matches the shopping list ID
  final locations = taskDetails['locations'] as List? ?? [];
  final locationIds = locations.map((location) => location['id']?.toString()).toList();
  if (locationIds.contains(clickup.workspace.listIds.shopping)) {
    return true;
  }

  return false;
}

/// Moves a task to the shopping list
///
/// [taskId] - The ClickUp task ID
/// [taskDetails] - Complete task details from ClickUp API
Future<void> moveToShoppingList(String taskId, Map<String, dynamic> taskDetails) async {
  try {
    // Make the API call to move the task to the shopping list
    final response = await http.post(
      Uri.parse('${clickup.API_BASE_URL}/list/${clickup.workspace.listIds.shopping}/task/$taskId'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      stdout.writeln('[PurchaseTags] Successfully moved task $taskId to shopping list');
    } else {
      stderr.writeln(
          '[PurchaseTags] Failed to move task $taskId to shopping list. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[PurchaseTags] Error moving task $taskId to shopping list: $e');
  }
}

/// Removes a task from the shopping list
///
/// [taskId] - The ClickUp task ID
/// [taskDetails] - Complete task details from ClickUp API
Future<void> removeFromShoppingList(String taskId, Map<String, dynamic> taskDetails) async {
  try {
    // Make the API call to remove the task from the shopping list
    final response = await http.delete(
      Uri.parse('${clickup.API_BASE_URL}/list/${clickup.workspace.listIds.shopping}/task/$taskId'),
      headers: {
        'Authorization': clickup.token,
        'Content-Type': 'application/json',
      },
    );

    if (response.statusCode == 200) {
      stdout.writeln('[PurchaseTags] Successfully removed task $taskId from shopping list');
    } else {
      stderr.writeln(
          '[PurchaseTags] Failed to remove task $taskId from shopping list. Status: ${response.statusCode}, Response: ${response.body}');
    }
  } catch (e) {
    stderr.writeln('[PurchaseTags] Error removing task $taskId from shopping list: $e');
  }
}
