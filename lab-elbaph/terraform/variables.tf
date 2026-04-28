variable "region" {
  description = "AWS region for the lab deployment."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to the created resources."
  type        = string
  default     = "elbaph-lab"
}

variable "office_cidr" {
  description = "Source CIDR whose traffic is forwarded on the ops ALB; all other clients get the listener default fixed response (403)."
  type        = string
  default     = "1.2.3.4/32"
}

variable "allowed_country_codes" {
  description = "CloudFront geo restriction allowlist."
  type        = list(string)
  default     = ["JP"]
}

variable "instance_type" {
  description = "EC2 instance type for the lab."
  type        = string
  default     = "t3.micro"
}
