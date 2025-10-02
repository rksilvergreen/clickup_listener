import 'dart:io';

// -------- Constants --------
const String API_BASE_URL = "https://api.clickup.com/api/v2";

// -------- Environment File Name Getter --------
String get envFileName {
  final clickupEnvFile = Platform.environment['CLICKUP_ENV_FILE'];
  if (clickupEnvFile == null || clickupEnvFile.isEmpty) {
    throw ArgumentError('CLICKUP_ENV_FILE environment variable must be set');
  }
  return clickupEnvFile;
}

// -------- Configuration Classes --------

/// Webhook Configuration
class WebhookConfig {
  final String endpointBaseUrl;
  final String endpointRoute;
  final List<WebhookItem> webhooks;

  WebhookConfig({
    required this.endpointBaseUrl,
    required this.endpointRoute,
    required this.webhooks,
  });

  factory WebhookConfig.fromMap(Map<String, dynamic> map) {
    final webhooksList = (map["list"] as List?) ?? [];
    return WebhookConfig(
      endpointBaseUrl: map["endpoint_base_url"] as String,
      endpointRoute: map["endpoint_route"] as String,
      webhooks: webhooksList.map((item) => WebhookItem.fromMap(item)).toList(),
    );
  }
}

/// Individual Webhook Item
class WebhookItem {
  final String id;
  final String secret;

  WebhookItem({
    required this.id,
    required this.secret,
  });

  factory WebhookItem.fromMap(Map<String, dynamic> map) {
    return WebhookItem(
      id: map["id"] as String,
      secret: map["secret"] as String,
    );
  }
}

/// Workspace Configuration
class WorkspaceConfig {
  final String id;
  final TaskTypeIds taskTypeIds;
  final ListIds listIds;
  final CustomFieldIds customFieldIds;
  final TagNames tagNames;

  WorkspaceConfig({
    required this.id,
    required this.taskTypeIds,
    required this.listIds,
    required this.customFieldIds,
    required this.tagNames,
  });

  factory WorkspaceConfig.fromMap(Map<String, dynamic> map) {
    return WorkspaceConfig(
      id: map["id"] as String,
      taskTypeIds: TaskTypeIds.fromMap(map["task_type_ids"] as Map<String, dynamic>),
      listIds: ListIds.fromMap(map["list_ids"] as Map<String, dynamic>),
      customFieldIds: CustomFieldIds.fromMap(map["custom_field_ids"] as Map<String, dynamic>),
      tagNames: TagNames.fromMap(map["tag_names"] as Map<String, dynamic>),
    );
  }
}

/// Task Type IDs Configuration
class TaskTypeIds {
  final String event;
  final String record;

  TaskTypeIds({required this.event, required this.record});

  factory TaskTypeIds.fromMap(Map<String, dynamic> map) {
    return TaskTypeIds(
      event: map["event"] as String,
      record: map["record"] as String,
    );
  }
}

/// List IDs Configuration
class ListIds {
  final String shopping;

  ListIds({required this.shopping});

  factory ListIds.fromMap(Map<String, dynamic> map) {
    return ListIds(
      shopping: map["shopping"] as String,
    );
  }
}

/// Custom Field IDs Configuration
class CustomFieldIds {
  final String startTime;
  final String endTime;
  final String relevanceNum;
  final String relevanceUnit;
  final String relevanceDate;
  final String timestamp;

  CustomFieldIds({
    required this.startTime,
    required this.endTime,
    required this.relevanceNum,
    required this.relevanceUnit,
    required this.relevanceDate,
    required this.timestamp,
  });

  factory CustomFieldIds.fromMap(Map<String, dynamic> map) {
    return CustomFieldIds(
      startTime: map["start_time"] as String,
      endTime: map["end_time"] as String,
      relevanceNum: map["relevance_num"] as String,
      relevanceUnit: map["relevance_unit"] as String,
      relevanceDate: map["relevance_date"] as String,
      timestamp: map["timestamp"] as String,
    );
  }
}

/// Tag Names Configuration
class TagNames {
  final String purchase;

  TagNames({required this.purchase});

  factory TagNames.fromMap(Map<String, dynamic> map) {
    return TagNames(
      purchase: map["purchase"] as String,
    );
  }
}

// -------- Top Level Variables --------
late final String token;
late final WebhookConfig webhooks;
late final WorkspaceConfig workspace;

// -------- Configuration Loading --------

void set(Map<String, dynamic> map) {
  // Create top level configuration objects
  token = map["token"] as String;
  webhooks = WebhookConfig.fromMap(map["webhooks"] as Map<String, dynamic>);
  workspace = WorkspaceConfig.fromMap(map["workspace"] as Map<String, dynamic>);

  stdout.writeln("[ClickUp] Configuration loaded successfully");
}
