variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "project" {
  type        = string
  default     = "eks"
  description = "Project name"
}

variable "create_role" {
  type    = bool
  default = true
}

variable "attach_efs_csi_policy" {
  type    = bool
  default = true
}

variable "addons" {
  type = list(object({
    name    = string
    version = string
  }))
  default = [
    {
      name    = "aws-efs-csi-driver"
      version = "v1.5.8-eksbuild.1"
    }
  ]
}

