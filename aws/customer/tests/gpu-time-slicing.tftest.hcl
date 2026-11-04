# Run with terraform test -filter=tests/gpu-time-slicing.tftest.hcl after backend-disabled init.
# All providers are mocked; these targeted plans never read live state or contact AWS/Kubernetes.
# gpu_time_slicing_replicas > 1 makes the NVIDIA device plugin advertise that many nvidia.com/gpu per
# physical GPU (its time-slicing config), so a second embedder pod can start beside the first.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "tls" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
override_module {
  target = module.eks
  outputs = {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/TEST"
    oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/TEST"
    cluster_name      = "test-cluster"
    cluster_endpoint  = "https://example.invalid"
    cluster_ca_data   = "dGVzdA=="
  }
}
variables {
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
}
run "off_by_default_renders_no_sharing_config" {
  command = plan
  plan_options { target = [helm_release.nvidia_device_plugin] }
  assert {
    condition     = length(helm_release.nvidia_device_plugin) == 1 && length(helm_release.nvidia_device_plugin[0].values) == 1
    error_message = "With time-slicing off the device plugin must get only its node selector and toleration values, exactly as before."
  }
  assert {
    condition     = !strcontains(join("\n", helm_release.nvidia_device_plugin[0].values), "timeSlicing")
    error_message = "Time-slicing must be opt-in: the default install must not configure it."
  }
  assert {
    condition = helm_release.nvidia_device_plugin[0].values[0] == yamlencode({
      nodeSelector = {
        workload = "embedder"
      }
      tolerations = [
        {
          key      = "workload"
          operator = "Equal"
          value    = "embedder"
          effect   = "NoSchedule"
        }
      ]
    })
    error_message = "With time-slicing off the values document must be exactly the one the release had before the variable existed."
  }
}
run "one_replica_is_the_same_as_off" {
  command = plan
  variables { gpu_time_slicing_replicas = 1 }
  plan_options { target = [helm_release.nvidia_device_plugin] }
  assert {
    condition     = length(helm_release.nvidia_device_plugin[0].values) == 1
    error_message = "One replica per GPU is no sharing and must render no sharing config."
  }
}
run "two_replicas_configure_time_slicing" {
  command = plan
  variables { gpu_time_slicing_replicas = 2 }
  plan_options { target = [helm_release.nvidia_device_plugin] }
  assert {
    condition     = length(helm_release.nvidia_device_plugin[0].values) == 2
    error_message = "A second values document carries the sharing config."
  }
  assert {
    condition     = yamldecode(yamldecode(helm_release.nvidia_device_plugin[0].values[1]).config.map.default).sharing.timeSlicing.resources[0].name == "nvidia.com/gpu"
    error_message = "Time-slicing must apply to nvidia.com/gpu."
  }
  assert {
    condition     = yamldecode(yamldecode(helm_release.nvidia_device_plugin[0].values[1]).config.map.default).sharing.timeSlicing.resources[0].replicas == 2
    error_message = "The replicas must be the variable's value."
  }
  assert {
    condition     = yamldecode(yamldecode(helm_release.nvidia_device_plugin[0].values[1]).config.map.default).sharing.timeSlicing.renameByDefault == false
    error_message = "The resource must keep the name nvidia.com/gpu, so the embedder's request does not change."
  }
  assert {
    condition     = yamldecode(yamldecode(helm_release.nvidia_device_plugin[0].values[1]).config.map.default).version == "v1"
    error_message = "The plugin config file is version v1."
  }
  assert {
    condition     = yamldecode(helm_release.nvidia_device_plugin[0].values[0]).nodeSelector.workload == "embedder"
    error_message = "The node selector values must stay."
  }
}
run "failing_requests_above_one_is_on" {
  command = plan
  variables { gpu_time_slicing_replicas = 2 }
  plan_options { target = [helm_release.nvidia_device_plugin] }
  assert {
    condition     = yamldecode(yamldecode(helm_release.nvidia_device_plugin[0].values[1]).config.map.default).sharing.timeSlicing.failRequestsGreaterThanOne == true
    error_message = "A request for more than one slice must fail loudly, not get a share that is not a bigger share."
  }
}
run "no_device_plugin_no_sharing" {
  command = plan
  variables {
    enable_nvidia_device_plugin = false
    gpu_time_slicing_replicas   = 2
  }
  expect_failures = [var.gpu_time_slicing_replicas]
}
run "reject_zero_replicas" {
  command = plan
  variables { gpu_time_slicing_replicas = 0 }
  plan_options { target = [helm_release.nvidia_device_plugin] }
  expect_failures = [var.gpu_time_slicing_replicas]
}
run "reject_excessive_replicas" {
  command = plan
  variables { gpu_time_slicing_replicas = 17 }
  plan_options { target = [helm_release.nvidia_device_plugin] }
  expect_failures = [var.gpu_time_slicing_replicas]
}
run "three_replicas_are_carried_through" {
  command = plan
  variables { gpu_time_slicing_replicas = 3 }
  plan_options { target = [helm_release.nvidia_device_plugin] }
  assert {
    condition     = yamldecode(yamldecode(helm_release.nvidia_device_plugin[0].values[1]).config.map.default).sharing.timeSlicing.resources[0].replicas == 3
    error_message = "The replicas must be the variable's value, not a fixed 2."
  }
}
run "reject_fractional_replicas" {
  command = plan
  variables { gpu_time_slicing_replicas = 1.5 }
  plan_options { target = [helm_release.nvidia_device_plugin] }
  expect_failures = [var.gpu_time_slicing_replicas]
}
