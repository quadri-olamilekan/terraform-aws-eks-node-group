terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.32.0"
    }

    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.13.11"
    }

  }
  backend "s3" {
    bucket = "s3-eks-iam-roles-repo-12-source"
    key    = "eks-nodes/terraform.tfstate"
    #dynamodb_table = "terraform-lock"
    region = "us-east-1"

  }

}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform" #replace
    }
  }
}

provider "kubernetes" {
  host                   = local.host
  cluster_ca_certificate = local.certificate
  token                  = local.token
}

provider "kubectl" {
  host                   = local.host
  cluster_ca_certificate = local.certificate
  token                  = local.token
  load_config_file       = false
}

provider "helm" {
  kubernetes {
    host                   = local.host
    cluster_ca_certificate = local.certificate
    token                  = local.token
  }
}

data "aws_eks_cluster_auth" "cluster" {
  name = data.terraform_remote_state.network.outputs.cluster_name
}

locals {
  host        = data.terraform_remote_state.network.outputs.cluster_endpoint
  certificate = base64decode(data.terraform_remote_state.network.outputs.cluster_certificate_authority_data)
  token       = data.aws_eks_cluster_auth.cluster.token
}
