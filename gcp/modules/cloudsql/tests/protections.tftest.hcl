# Pure mocked plans: no credentials or API calls. The two instance-level protections (settings block) are
# inputs, deletion_protection_enabled and retain_backups_on_delete. Both default to off, which is what every
# caller that does not pass them already plans; each can be set on and then shows in the planned settings.
mock_provider "google" {}
mock_provider "random" {}

variables {
  project_id             = "protections-test"
  region                 = "us-east1"
  name_prefix            = "t"
  environment            = "ci"
  network_id             = "projects/protections-test/global/networks/n"
  database_name          = "chaindb"
  tier                   = "db-custom-1-3840"
  workload_identity_pool = "protections-test.svc.id.goog"
}

run "defaults_keep_both_off" {
  command = plan
  assert {
    condition     = google_sql_database_instance.this.settings[0].deletion_protection_enabled == false
    error_message = "The instance-level deletion protection must default to off."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].retain_backups_on_delete == false
    error_message = "Retaining backups on delete must default to off."
  }
}

run "both_can_be_set_on" {
  command = plan
  variables {
    instance_deletion_protection_enabled = true
    retain_backups_on_delete             = true
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].deletion_protection_enabled == true
    error_message = "instance_deletion_protection_enabled must reach settings.deletion_protection_enabled."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].retain_backups_on_delete == true
    error_message = "retain_backups_on_delete must reach settings.retain_backups_on_delete."
  }
}

run "the_terraform_level_guard_is_independent" {
  command = plan
  variables {
    deletion_protection                  = false
    instance_deletion_protection_enabled = true
  }
  assert {
    condition     = google_sql_database_instance.this.deletion_protection == false
    error_message = "deletion_protection (the Terraform-level guard) must not follow the instance-level input."
  }
  assert {
    condition     = google_sql_database_instance.this.settings[0].deletion_protection_enabled == true
    error_message = "The instance-level input must not follow the Terraform-level guard."
  }
}
