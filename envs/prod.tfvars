environment = "prod"
region      = "ap-south-1"

# Survive the loss of an AZ
az_count                   = 3
single_nat_gateway         = false # one NAT per AZ
enable_interface_endpoints = true

db_instance_class       = "db.r6g.large"
db_allocated_storage    = 100
db_max_allocated_storage = 1000
db_multi_az             = true
db_performance_insights = true
cache_node_type         = "cache.r6g.large"
cache_num_nodes         = 2

log_retention_days = 90
waf_rate_limit     = 2000

# CHANGE THESE
alert_email             = "oncall@example.com"
notification_from_email = "orders@example.com"
monthly_budget_usd      = 5000

enable_custom_domain = true
domain_name          = "example.com"
app_subdomain        = "shop"

services = {
  catalog = {
    port          = 8080
    cpu           = 1024
    memory        = 2048
    min_count     = 3
    max_count     = 40
    priority      = 10
    path_patterns = ["/api/catalog/*", "/api/search/*"]
    health_path   = "/"
  }
  orders = {
    port          = 8080
    cpu           = 1024
    memory        = 2048
    min_count     = 3
    max_count     = 40
    priority      = 20
    path_patterns = ["/api/orders/*", "/api/cart/*", "/api/checkout/*"]
    health_path   = "/"
  }
}
