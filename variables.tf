############################
# Identity and environment
############################
variable "project" {
  description = "Short name used as a prefix for every resource."
  type        = string
  default     = "fashionhub"
}

variable "environment" {
  description = "dev, staging or prod. Prod turns on deletion protection, Multi-AZ and longer backups."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" {
  description = "Primary AWS region."
  type        = string
  default     = "ap-south-1"
}

############################
# Network
############################
variable "vpc_cidr" {
  description = "Must be a /16. Subnets are carved out as /20 blocks."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16 CIDR block."
  }
}

variable "az_count" {
  description = "Number of Availability Zones to spread across (2 or 3)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "true = one shared NAT (cheap, dev). false = one NAT per AZ (survives an AZ outage, prod)."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "Private endpoints for ECR, Logs, Secrets Manager, SNS, SQS. Cuts NAT traffic, adds a fixed monthly cost per AZ."
  type        = bool
  default     = false
}

############################
# Domain (optional)
############################
variable "enable_custom_domain" {
  description = "true = use your Route 53 zone, ACM certificates and an HTTPS origin. false = use the *.cloudfront.net name."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Existing public Route 53 hosted zone name, e.g. example.com. Only used when enable_custom_domain = true."
  type        = string
  default     = ""
}

variable "app_subdomain" {
  description = "Storefront host, e.g. shop gives shop.example.com."
  type        = string
  default     = "shop"
}

############################
# Services (ECS Fargate)
############################
variable "services" {
  description = "Backend services. The keys catalog and orders are required (task roles are written for them)."
  type = map(object({
    port          = number
    cpu           = number
    memory        = number
    min_count     = number
    max_count     = number
    priority      = number
    path_patterns = list(string)
    health_path   = string
  }))

  default = {
    catalog = {
      port          = 8080
      cpu           = 256
      memory        = 512
      min_count     = 1
      max_count     = 4
      priority      = 10
      path_patterns = ["/api/catalog/*", "/api/search/*"]
      health_path   = "/"
    }
    orders = {
      port          = 8080
      cpu           = 256
      memory        = 512
      min_count     = 1
      max_count     = 4
      priority      = 20
      path_patterns = ["/api/orders/*", "/api/cart/*", "/api/checkout/*"]
      health_path   = "/"
    }
  }

  validation {
    condition     = alltrue([for k in ["catalog", "orders"] : contains(keys(var.services), k)])
    error_message = "services must contain the keys catalog and orders."
  }
}

variable "container_images" {
  description = "Image per service, e.g. { catalog = \"123.dkr.ecr.ap-south-1.amazonaws.com/fashionhub-dev-catalog:abc123\" }. Empty = placeholder image."
  type        = map(string)
  default     = {}
}

variable "placeholder_image" {
  description = "Used until your CI pushes a real image. Must listen on the service port (8080)."
  type        = string
  default     = "public.ecr.aws/nginx/nginx-unprivileged:stable"
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64 (Graviton, about 20% cheaper). Your images must match."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

############################
# Data stores
############################
variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB."
  type        = number
  default     = 100
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_performance_insights" {
  description = "Not supported on the smallest burstable classes; enable for prod sizes."
  type        = bool
  default     = false
}

variable "cache_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "cache_num_nodes" {
  description = "1 = no replica. 2 or more = replicas with automatic failover."
  type        = number
  default     = 1
}

############################
# Edge, observability, cost
############################
variable "cloudfront_price_class" {
  description = "PriceClass_100 (NA/EU), PriceClass_200 (adds Asia incl. India), PriceClass_All."
  type        = string
  default     = "PriceClass_200"
}

variable "waf_rate_limit" {
  description = "Max requests per 5 minutes per IP before WAF blocks."
  type        = number
  default     = 2000
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "alert_email" {
  description = "Receives alarm and budget notifications. Confirm the SNS subscription email after apply."
  type        = string
}

variable "notification_from_email" {
  description = "Verified SES sender for customer emails. SES sends a verification link to this address."
  type        = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 200
}
