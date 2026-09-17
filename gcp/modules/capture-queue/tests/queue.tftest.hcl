# Pure mocked plans: no project credentials, API calls, state backend or apply.
mock_provider "google" {}
mock_provider "google-beta" {}
variables {
  project_id            = "capture-queue-test"
  name                  = "test-captures"
  publisher_email       = "edge@capture-queue-test.iam.gserviceaccount.com"
  consumer_email        = "lake@capture-queue-test.iam.gserviceaccount.com"
  notification_channels = ["projects/capture-queue-test/notificationChannels/test"]
}
run "finite_retention_and_scoped_forwarding" {
  command = plan
  assert {
    condition     = google_pubsub_subscription.captures.message_retention_duration == "2678400s" && google_pubsub_subscription.dlq.message_retention_duration == "2678400s"
    error_message = "Source and DLQ must retain unacknowledged messages for 31 days."
  }
  assert {
    condition     = google_pubsub_subscription.captures.expiration_policy[0].ttl == "" && google_pubsub_subscription.dlq.expiration_policy[0].ttl == ""
    error_message = "Subscriptions must not expire during inactivity."
  }
  assert {
    condition     = google_pubsub_subscription.captures.dead_letter_policy[0].max_delivery_attempts == 5 && google_pubsub_subscription.captures.ack_deadline_seconds == 120
    error_message = "Delivery attempt and initial lease configuration changed."
  }
  assert {
    condition     = google_pubsub_topic_iam_member.publish.member == "serviceAccount:${var.publisher_email}" && google_pubsub_subscription_iam_member.consume.member == "serviceAccount:${var.consumer_email}" && google_pubsub_topic_iam_member.forward_dlq.role == "roles/pubsub.publisher" && google_pubsub_subscription_iam_member.forward_source.role == "roles/pubsub.subscriber"
    error_message = "Workloads and Pub/Sub service agent need narrowly scoped publication/subscription grants."
  }
  assert {
    condition     = length(google_monitoring_alert_policy.queue) == 4 && length(google_cloud_run_v2_service_iam_member.embedder) == 0
    error_message = "Native alerts are required; HTTP-only embedding needs no Cloud Run grants."
  }
  assert {
    condition     = alltrue([for alarm in google_monitoring_alert_policy.queue : strcontains(alarm.documentation[0].content, "https://github.com/try-caret/arbium-terraform/blob/main/aws/customer/QUEUE_RECOVERY.md")])
    error_message = "Every alarm must link to the customer recovery document shipped in the public mirror."
  }
}
run "shared_project_reuses_services_and_identity" {
  command = plan
  variables {
    manage_project_services    = false
    pubsub_service_agent_email = "service-123@gcp-sa-pubsub.iam.gserviceaccount.com"
  }
  assert {
    condition     = length(google_project_service.queue) == 0 && length(google_project_service_identity.pubsub) == 0
    error_message = "A second environment must not manage project-scoped APIs or the shared Pub/Sub identity."
  }
  assert {
    condition     = google_pubsub_topic_iam_member.forward_dlq.member == "serviceAccount:service-123@gcp-sa-pubsub.iam.gserviceaccount.com" && google_pubsub_subscription_iam_member.forward_source.member == "serviceAccount:service-123@gcp-sa-pubsub.iam.gserviceaccount.com"
    error_message = "Dead-letter forwarding must use the existing project service agent."
  }
}
run "private_embedder_grants_both_paths" {
  command = plan
  variables {
    embedder_cloud_run = { project = "capture-queue-test", location = "us-central1", name = "embedder" }
  }
  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.embedder) == 2 && google_cloud_run_v2_service_iam_member.embedder["lake"].role == "roles/run.invoker"
    error_message = "Queued and rollback embedding both need Cloud Run invocation rights."
  }
}
run "reject_unrouted_alerts" {
  command = plan
  variables { notification_channels = [] }
  expect_failures = [var.notification_channels]
}
