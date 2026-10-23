# Pure mocked plans: no credentials or API calls. The pool name is the member of a Workload Identity
# binding (`serviceAccount:<pool>[ns/ksa]`); an empty or already-suffixed value would plan and then fail
# at apply, so the variable refuses it. secrets/tests/pool.tftest.hcl carries the same cases for the
# same condition (the private repo pins that the two conditions are identical).
mock_provider "google" {}
mock_provider "random" {}

variables {
  project_id    = "pool-test"
  region        = "us-east1"
  name_prefix   = "t"
  environment   = "ci"
  network_id    = "projects/pool-test/global/networks/n"
  database_name = "chaindb"
  tier          = "db-custom-1-3840"
}

run "pool_of_a_project" {
  command = plan
  variables {
    workload_identity_pool = "my-project.svc.id.goog"
  }
  assert {
    condition     = google_service_account_iam_member.cloudsql_proxy_wi[0].member == "serviceAccount:my-project.svc.id.goog[arbium/cloud-sql-proxy]"
    error_message = "The binding member must be the pool with the namespace and service account appended."
  }
}

run "pool_of_a_domain_scoped_project" {
  command = plan
  variables {
    workload_identity_pool = "example.com:proj.svc.id.goog"
  }
}

run "empty_is_refused" {
  command = plan
  variables {
    workload_identity_pool = ""
  }
  expect_failures = [var.workload_identity_pool]
}

run "no_project_is_refused" {
  command = plan
  variables {
    workload_identity_pool = ".svc.id.goog"
  }
  expect_failures = [var.workload_identity_pool]
}

run "a_member_suffix_is_refused" {
  command = plan
  variables {
    workload_identity_pool = "x.svc.id.goog[ns/ksa]"
  }
  expect_failures = [var.workload_identity_pool]
}

run "a_trailing_domain_is_refused" {
  command = plan
  variables {
    workload_identity_pool = "x.svc.id.goog.evil"
  }
  expect_failures = [var.workload_identity_pool]
}

run "a_slash_is_refused" {
  command = plan
  variables {
    workload_identity_pool = "a/b.svc.id.goog"
  }
  expect_failures = [var.workload_identity_pool]
}

run "a_bracket_is_refused" {
  command = plan
  variables {
    workload_identity_pool = "x[ns].svc.id.goog"
  }
  expect_failures = [var.workload_identity_pool]
}
