output "site_url" {
  description = "Open this in a browser once the frontend is uploaded."
  value       = var.enable_custom_domain ? "https://${local.fqdn}" : "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "cloudfront_distribution_id" {
  description = "Needed for cache invalidation after a frontend deploy."
  value       = aws_cloudfront_distribution.main.id
}

output "frontend_bucket" {
  description = "Upload the built single-page app here (aws s3 sync build/ s3://<bucket>)."
  value       = aws_s3_bucket.this["frontend"].bucket
}

output "media_bucket" {
  description = "Product images. Keys must start with media/."
  value       = aws_s3_bucket.this["media"].bucket
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "ecr_repository_urls" {
  description = "Push service images here, using an immutable tag such as the git SHA."
  value       = { for k, r in aws_ecr_repository.svc : k => r.repository_url }
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "db_endpoint" {
  value = aws_db_instance.orders.address
}

output "db_secret_arn" {
  description = "Secrets Manager secret holding the database credentials (managed by RDS)."
  value       = aws_db_instance.orders.master_user_secret[0].secret_arn
}

output "order_events_topic_arn" {
  value = aws_sns_topic.order_events.arn
}

output "queue_urls" {
  value = { for k, q in aws_sqs_queue.main : k => q.url }
}

output "dlq_urls" {
  value = { for k, q in aws_sqs_queue.dlq : k => q.url }
}
