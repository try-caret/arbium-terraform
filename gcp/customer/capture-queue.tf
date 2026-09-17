# Customer installs supply their existing workload GSAs; do not create a new identity hierarchy.
variable "capture_queue" {
  description = "Optional Pub/Sub provisioning. Existing GSAs must be in this project; map the returned emails to the existing chart serviceAccount annotation hooks."
  type = object({
    publisher_email       = string
    consumer_email        = string
    namespace             = optional(string, "arbium")
    publisher_ksa         = optional(string, "chaindb-edge-fns")
    consumer_ksa          = optional(string, "chaindb-capturelake")
    notification_channels = list(string)
    embedder_cloud_run    = optional(object({ project = string, location = string, name = string }))
  })
  default = null
}

resource "google_service_account_iam_member" "capture_queue_wi" {
  for_each = var.capture_queue == null ? {} : {
    edge = { email = var.capture_queue.publisher_email, ksa = var.capture_queue.publisher_ksa }
    lake = { email = var.capture_queue.consumer_email, ksa = var.capture_queue.consumer_ksa }
  }
  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value.email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.capture_queue.namespace}/${each.value.ksa}]"
}

module "capture_queue" {
  count                 = var.capture_queue == null ? 0 : 1
  source                = "../modules/capture-queue"
  project_id            = var.project_id
  name                  = "${var.name_prefix}-${var.environment}-captures"
  publisher_email       = var.capture_queue.publisher_email
  consumer_email        = var.capture_queue.consumer_email
  notification_channels = var.capture_queue.notification_channels
  embedder_cloud_run    = var.capture_queue.embedder_cloud_run
  labels                = local.labels
  depends_on            = [google_service_account_iam_member.capture_queue_wi]
}

output "capture_queue" {
  description = "Queue identifiers and existing workload emails for the chart env/serviceAccount hooks. This does not enable publication or consumption."
  value = var.capture_queue == null ? null : {
    topic            = module.capture_queue[0].topic
    subscription     = module.capture_queue[0].subscription
    dlq_subscription = module.capture_queue[0].dlq_subscription
    publisher_email  = var.capture_queue.publisher_email
    consumer_email   = var.capture_queue.consumer_email
  }
}
