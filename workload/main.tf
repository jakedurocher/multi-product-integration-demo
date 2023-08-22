terraform {
  required_providers {
    doormat = {
      source  = "doormat.hashicorp.services/hashicorp-security/doormat"
      version = "~> 0.0.6"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.8.0"
    }

    vault = {
      source = "hashicorp/vault"
      version = "~> 3.18.0"
    }

    nomad = {
      source = "hashicorp/nomad"
      version = "2.0.0-beta.1"
    }
  }
}

provider "doormat" {}

data "doormat_aws_credentials" "creds" {
  provider = doormat
  role_arn = "arn:aws:iam::365006510262:role/tfc-doormat-role_6_workload"
}

provider "aws" {
  region     = var.region
  access_key = data.doormat_aws_credentials.creds.access_key
  secret_key = data.doormat_aws_credentials.creds.secret_key
  token      = data.doormat_aws_credentials.creds.token
}

data "terraform_remote_state" "hcp_clusters" {
  backend = "remote"

  config = {
    organization = var.tfc_account_name
    workspaces = {
      name = "2_hcp-clusters"
    }
  }
}

data "terraform_remote_state" "nomad_cluster" {
  backend = "remote"

  config = {
    organization = var.tfc_account_name
    workspaces = {
      name = "3_nomad-cluster"
    }
  }
}

provider "vault" {
  address = data.terraform_remote_state.hcp_clusters.outputs.vault_public_endpoint
  token = data.terraform_remote_state.hcp_clusters.outputs.vault_root_token
  namespace = "admin"
}

data "vault_kv_secret_v2" "bootstrap" {
  mount = data.terraform_remote_state.nomad_cluster.outputs.bootstrap_kv
  name  = "nomad_bootstrap/SecretID"
}

provider "nomad" {
  address = data.terraform_remote_state.nomad_cluster.outputs.nomad_public_endpoint
  secret_id = data.vault_kv_secret_v2.bootstrap.data["SecretID"]
}

resource "nomad_job" "mongodb" {
  jobspec = file("${path.module}/nomad-jobs/mongodb.hcl")
}

resource "null_resource" "wait_for_db" {
  depends_on = [nomad_job.mongodb]

  provisioner "local-exec" {
    command = "sleep 5 && bash wait-for-nomad-job.sh ${nomad_job.mongodb.id}"
  }
}

resource "vault_database_secrets_mount" "mongodb" {
  depends_on = [
    null_resource.wait_for_db
  ]
  lifecycle {
    ignore_changes = [
      mongodb[0].password
    ]
  }
  path = "mongodb"

  mongodb {
    name                 = "mongodb-on-nomad"
    username             = "admin"
    password             = "password"
    connection_url       = "mongodb://{{username}}:{{password}}@demo-mongodb.service.consul:27017/admin?tls=false"
    max_open_connections = 0
    allowed_roles = [
      "demo",
    ]
  }
}

resource "null_resource" "mongodb_root_rotation" {
  depends_on = [
    vault_database_secrets_mount.mongodb
  ]
  provisioner "local-exec" {
    command = "curl --header \"X-Vault-Token: ${data.terraform_remote_state.hcp_clusters.outputs.vault_root_token}\" --request POST ${data.terraform_remote_state.hcp_clusters.outputs.vault_public_endpoint}/v1/${vault_database_secrets_mount.mongodb.path}/rotate-root/mongodb-on-nomad"
  }
}

resource "vault_database_secret_backend_role" "mongodb" {
  name    = "demo"
  backend = vault_database_secrets_mount.mongodb.path
  db_name = vault_database_secrets_mount.mongodb.mongodb[0].name
  creation_statements = [
    "{\"db\": \"admin\",\"roles\": [{\"role\": \"root\"}]}"
  ]
}

resource "nomad_job" "dashboard" {
  depends_on = [
    vault_database_secret_backend_role.mongodb
  ]
  jobspec = file("${path.module}/nomad-jobs/dashboard.hcl")
}


# // Optional Full KVM based VM Example
# resource "nomad_job" "fullvm" {
#  jobspec = file("${path.module}/nomad-jobs/mongodb-vmdk.hcl")
# }