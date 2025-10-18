variable "region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "eu-west-2"
}

variable "instance_count" {
  description = "Number of EC2 instances to create"
  type        = number
  default     = 1
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "c5d.large"  # 2 vCPU, 4GB RAM, 50GB NVMe instance store (smallest c5d)
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.small"  # Upgraded for load testing (2GB RAM, more connections)
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "fleetlm_dev"
}

variable "db_username" {
  description = "Database master username"
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Database master password"
  type        = string
  default     = "postgres"
}

variable "key_name" {
  description = "SSH key pair name (must exist in AWS)"
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key content (if key_name not provided)"
  type        = string
  default     = ""
}
