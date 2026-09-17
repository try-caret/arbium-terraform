terraform {
  required_providers {
    google      = { source = "hashicorp/google", version = ">= 6.0" }
    google-beta = { source = "hashicorp/google-beta", version = ">= 6.0" }
  }
}

variable "project_id" { type = string }
variable "name" { type = string }
variable "publisher_email" { type = string }
variable "consumer_email" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}
variable "notification_channels" {
  type = list(string)
  validation {
    condition     = length(var.notification_channels) > 0
    error_message = "Provide at least one existing Cloud Monitoring notification channel."
  }
}
variable "embedder_cloud_run" {
  description = "Optional private embedder service. Grants invocation to lake and edge for rollback; configure the full EMBEDDER_URL separately."
  type        = object({ project = string, location = string, name = string })
  default     = null
}
variable "manage_project_services" {
  type        = bool
  default     = true
  description = "Manage shared Pub/Sub/Monitoring APIs and the Pub/Sub service identity. Disable for a second environment in an already-managed project."
}
variable "pubsub_service_agent_email" {
  type        = string
  default     = null
  description = "Existing Pub/Sub service agent when manage_project_services is false."
  validation {
    condition     = var.manage_project_services || (var.pubsub_service_agent_email != null && var.pubsub_service_agent_email != "")
    error_message = "pubsub_service_agent_email is required when project services are managed elsewhere."
  }
}

resource "google_project_service" "queue" {
  for_each           = var.manage_project_services ? toset(["pubsub.googleapis.com", "monitoring.googleapis.com"]) : toset([])
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

resource "google_project_service_identity" "pubsub" {
  count      = var.manage_project_services ? 1 : 0
  provider   = google-beta
  project    = var.project_id
  service    = "pubsub.googleapis.com"
  depends_on = [google_project_service.queue]
}
moved {
  from = google_project_service_identity.pubsub
  to   = google_project_service_identity.pubsub[0]
}
locals {
  pubsub_service_agent_email = var.manage_project_services ? google_project_service_identity.pubsub[0].email : var.pubsub_service_agent_email
}

resource "google_pubsub_topic" "captures" {
  project    = var.project_id
  name       = var.name
  labels     = var.labels
  depends_on = [google_project_service.queue]
}
resource "google_pubsub_topic" "dlq" {
  project    = var.project_id
  name       = "${var.name}-dlq"
  labels     = var.labels
  depends_on = [google_project_service.queue]
}
resource "google_pubsub_subscription" "dlq" {
  project                    = var.project_id
  name                       = "${var.name}-dlq"
  topic                      = google_pubsub_topic.dlq.id
  message_retention_duration = "2678400s"
  ack_deadline_seconds       = 120
  expiration_policy { ttl = "" }
  labels = var.labels
}
resource "google_pubsub_subscription" "captures" {
  project                    = var.project_id
  name                       = var.name
  topic                      = google_pubsub_topic.captures.id
  message_retention_duration = "2678400s"
  ack_deadline_seconds       = 120
  expiration_policy { ttl = "" }
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }
  labels = var.labels
  # No unretained dead-letter interval: the DLQ subscription exists first.
  depends_on = [google_pubsub_subscription.dlq, google_pubsub_topic_iam_member.forward_dlq]
}
resource "google_pubsub_topic_iam_member" "publish" {
  project = var.project_id
  topic   = google_pubsub_topic.captures.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.publisher_email}"
}
resource "google_pubsub_subscription_iam_member" "consume" {
  project      = var.project_id
  subscription = google_pubsub_subscription.captures.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${var.consumer_email}"
}
resource "google_pubsub_topic_iam_member" "forward_dlq" {
  project    = var.project_id
  topic      = google_pubsub_topic.dlq.name
  role       = "roles/pubsub.publisher"
  member     = "serviceAccount:${local.pubsub_service_agent_email}"
  depends_on = [google_project_service_identity.pubsub]
}
resource "google_pubsub_subscription_iam_member" "forward_source" {
  project      = var.project_id
  subscription = google_pubsub_subscription.captures.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${local.pubsub_service_agent_email}"
  depends_on   = [google_project_service_identity.pubsub]
}

resource "google_cloud_run_v2_service_iam_member" "embedder" {
  for_each = var.embedder_cloud_run == null ? {} : { edge = var.publisher_email, lake = var.consumer_email }
  project  = var.embedder_cloud_run.project
  location = var.embedder_cloud_run.location
  name     = var.embedder_cloud_run.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${each.value}"
}

# Use native subscription backlog/in-flight dashboards; no custom queue telemetry service.
resource "google_monitoring_alert_policy" "queue" {
  for_each = {
    freshness = { dlq = false, metric = "oldest_unacked_message_age", threshold = 60, duration = "300s" }
    outage    = { dlq = false, metric = "oldest_unacked_message_age", threshold = 86400, duration = "60s" }
    dlq       = { dlq = true, metric = "num_undelivered_messages", threshold = 0, duration = "60s" }
    dlq_age   = { dlq = true, metric = "oldest_unacked_message_age", threshold = 3600, duration = "60s" }
  }
  project               = var.project_id
  display_name          = "${var.name}-${each.key}"
  combiner              = "OR"
  notification_channels = var.notification_channels
  conditions {
    display_name = "Capture queue ${each.key}"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"${each.value.dlq ? google_pubsub_subscription.dlq.name : google_pubsub_subscription.captures.name}\" AND metric.type = \"pubsub.googleapis.com/subscription/${each.value.metric}\""
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold
      duration        = each.value.duration
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
  documentation {
    content   = "Investigate capture backlog before derive lookback or finite retention expires. Follow the [customer recovery procedure](https://github.com/try-caret/arbium-terraform/blob/main/aws/customer/QUEUE_RECOVERY.md) (also included in the pinned release); do not replay without fixing the cause."
    mime_type = "text/markdown"
  }
  depends_on = [google_project_service.queue]
}

output "topic" { value = google_pubsub_topic.captures.id }
output "subscription" { value = google_pubsub_subscription.captures.id }
output "dlq_subscription" { value = google_pubsub_subscription.dlq.id }
