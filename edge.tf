############################
# DNS zone and certificates (only when enable_custom_domain = true)
############################
data "aws_route53_zone" "main" {
  count = var.enable_custom_domain ? 1 : 0

  name         = var.domain_name
  private_zone = false
}

# Certificate for the storefront. CloudFront only accepts certificates from us-east-1.
resource "aws_acm_certificate" "cf" {
  count    = var.enable_custom_domain ? 1 : 0
  provider = aws.us_east_1

  domain_name       = local.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cf_validation" {
  for_each = var.enable_custom_domain ? {
    for dvo in aws_acm_certificate.cf[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = data.aws_route53_zone.main[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cf" {
  count    = var.enable_custom_domain ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cf[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cf_validation : r.fqdn]
}

# Certificate for the ALB origin name (origin.<fqdn>), in the app region.
# Keeps CloudFront -> ALB encrypted too.
resource "aws_acm_certificate" "alb" {
  count = var.enable_custom_domain ? 1 : 0

  domain_name       = local.origin_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "alb_validation" {
  for_each = var.enable_custom_domain ? {
    for dvo in aws_acm_certificate.alb[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = data.aws_route53_zone.main[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "alb" {
  count = var.enable_custom_domain ? 1 : 0

  certificate_arn         = aws_acm_certificate.alb[0].arn
  validation_record_fqdns = [for r in aws_route53_record.alb_validation : r.fqdn]
}

resource "aws_route53_record" "origin" {
  count = var.enable_custom_domain ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = local.origin_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "site_a" {
  count = var.enable_custom_domain ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "site_aaaa" {
  count = var.enable_custom_domain ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = local.fqdn
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

############################
# WAF (CLOUDFRONT scope must be created in us-east-1)
############################
locals {
  waf_managed_groups = {
    AWSManagedRulesCommonRuleSet          = 10
    AWSManagedRulesKnownBadInputsRuleSet  = 20
    AWSManagedRulesSQLiRuleSet            = 30
    AWSManagedRulesAmazonIpReputationList = 40
  }
}

resource "aws_wafv2_web_acl" "cf" {
  provider = aws.us_east_1

  name        = "${local.name}-cloudfront"
  description = "Edge protection for the storefront"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.waf_managed_groups

    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-cloudfront"
    sampled_requests_enabled   = true
  }
}

############################
# CloudFront
############################
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${local.name}-s3-oac"
  description                       = "CloudFront signs requests to private S3 buckets"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Single-page-app routing done at the edge. A distribution-wide 404 -> index.html
# error rule would also rewrite genuine API 404s, so we rewrite only the S3 behavior.
resource "aws_cloudfront_function" "spa_rewrite" {
  name    = "${local.name}-spa-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Serve index.html for client-side routes (URIs without a file extension)"
  publish = true

  code = <<-EOT
    function handler(event) {
      var request = event.request;
      var last = request.uri.split('/').pop();
      if (last.indexOf('.') === -1) {
        request.uri = '/index.html';
      }
      return request;
    }
  EOT
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  comment             = "${local.name} storefront"
  default_root_object = "index.html"
  price_class         = var.cloudfront_price_class
  aliases             = var.enable_custom_domain ? [local.fqdn] : []
  web_acl_id          = aws_wafv2_web_acl.cf.arn

  # Origin 1: static single-page app
  origin {
    origin_id                = "frontend"
    domain_name              = aws_s3_bucket.this["frontend"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  # Origin 2: product images. Object keys must start with "media/" because
  # CloudFront passes the request path through to S3 unchanged.
  origin {
    origin_id                = "media"
    domain_name              = aws_s3_bucket.this["media"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  # Origin 3: the ALB, with the shared-secret header
  origin {
    origin_id   = "alb"
    domain_name = var.enable_custom_domain ? local.origin_fqdn : aws_lb.app.dns_name

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = var.enable_custom_domain ? "https-only" : "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
  }

  default_cache_behavior {
    target_origin_id           = "frontend"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_rewrite.arn
    }
  }

  ordered_cache_behavior {
    path_pattern               = "/media/*"
    target_origin_id           = "media"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.enable_custom_domain ? null : true
    acm_certificate_arn            = var.enable_custom_domain ? aws_acm_certificate_validation.cf[0].certificate_arn : null
    ssl_support_method             = var.enable_custom_domain ? "sni-only" : null
    minimum_protocol_version       = var.enable_custom_domain ? "TLSv1.2_2021" : null
  }

  depends_on = [aws_route53_record.origin]
}

############################
# Bucket policies: HTTPS only, and read access for this distribution only (OAC)
############################
data "aws_iam_policy_document" "bucket" {
  for_each = aws_s3_bucket.this

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${each.value.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this

  bucket     = each.value.id
  policy     = data.aws_iam_policy_document.bucket[each.key].json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# Browsers upload product images straight to S3 with presigned URLs, so the
# media bucket needs CORS for the storefront origin.
resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.this["media"].id

  cors_rule {
    allowed_methods = ["GET", "PUT", "HEAD"]
    allowed_origins = [var.enable_custom_domain ? "https://${local.fqdn}" : "https://${aws_cloudfront_distribution.main.domain_name}"]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}
