package test

import (
    "testing"
    "github.com/gruntwork-io/terratest/modules/terraform"
    "github.com/stretchr/testify/assert"
)

func TestBasicExample(t *testing.T) {
    terraformOptions := &terraform.Options{
        TerraformDir: "../../examples/basic",
        Vars: map[string]interface{}{
            "server_ip": "10.0.0.1",
            "ssh_private_key": "dummy-key-for-testing",
        },
    }

    defer terraform.Destroy(t, terraformOptions)
    terraform.InitAndPlan(t, terraformOptions)
}