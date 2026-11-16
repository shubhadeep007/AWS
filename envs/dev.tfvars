environment = "dev"
region      = "ap-south-1"

# Cheap and disposable
az_count                   = 2
single_nat_gateway         = true
enable_interface_endpoints = false

db_instance_class       = "db.t4g.medium"
db_multi_az             = false
db_performance_insights = false
cache_node_type         = "cache.t4g.micro"
cache_num_nodes         = 1

log_retention_days = 14

# CHANGE THESE
alert_email             = "you@example.com"
notification_from_email = "orders@example.com"
monthly_budget_usd      = 150

# Optional: use your own domain
enable_custom_domain = false
# domain_name          = "example.com"
# app_subdomain        = "shop-dev"

# services use the defaults from variables.tf (1 to 4 small tasks each)
