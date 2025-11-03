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
  # Ajusta si tu lab no tiene estas zonas
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# Clase de instancia. En labs, t3 suele ser más compatible que t4g.
variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
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

# 🔑 Nuevo: activar/desactivar Lambda y EventBridge
variable "enable_lambda" {
  type        = bool
  description = "Habilita/deshabilita Lambda y EventBridge"
  default     = false
}

# 🔑 Nuevo: ARN de rol existente para Lambda (solo se usa si enable_lambda = true)
variable "existing_lambda_role_arn" {
  description = "ARN de un rol existente confiado a lambda.amazonaws.com"
  type        = string
  default     = ""
}
