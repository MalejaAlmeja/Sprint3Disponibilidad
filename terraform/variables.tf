variable "project" {
  type    = string
  default = "consistency-experiment"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_engine_version" {
  type    = string
  default = "8.0.36"
}

variable "db_name" {
  type    = string
  default = "wms"
}

variable "db_user" {
  type    = string
  default = "wms_user"
}

variable "lambda_memory_mb" {
  type    = number
  default = 384
}

variable "lambda_timeout" {
  type    = number
  default = 5
}

variable "lambda_provisioned" {
  type    = number
  default = 2
}

variable "existing_lambda_role_arn" {
  description = "ARN de un rol existente con confianza en lambda.amazonaws.com"
  type        = string
  default     = ""
}