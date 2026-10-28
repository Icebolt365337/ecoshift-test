variable "project" {
  type    = string
  default = "carbon-windows"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "alert_email" {
  description = "Optional email address for pipeline failure alerts."
  type        = string
  default     = ""
}
