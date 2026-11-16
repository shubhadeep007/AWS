data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name    = "${var.project}-${var.environment}"
  is_prod = var.environment == "prod"
  azs     = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Custom domain naming (null when the feature is off)
  fqdn        = var.enable_custom_domain ? "${var.app_subdomain}.${var.domain_name}" : null
  origin_fqdn = var.enable_custom_domain ? "origin.${var.app_subdomain}.${var.domain_name}" : null

  # CloudFront -> ALB protocol
  alb_port = var.enable_custom_domain ? 443 : 80

  # Distinct container ports as strings (for_each needs string keys)
  service_ports = toset([for s in values(var.services) : tostring(s.port)])

  nat_count = var.single_nat_gateway ? 1 : var.az_count
}
