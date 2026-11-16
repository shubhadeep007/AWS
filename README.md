# FashionHub: production-style AWS shopping platform (Terraform)

Browser -> Route 53 -> CloudFront + WAF -> ALB -> ECS Fargate (catalog, orders)
-> RDS PostgreSQL, DynamoDB, Valkey. Order events: SNS -> SQS -> Lambda -> SES email.

The full walkthrough, design reasoning and interview questions are in the companion
study guide document.

## Status: read before you apply

- This code was written without access to a Terraform binary and has **not** been run through
  `terraform validate` or `plan`. Do that in a throwaway dev account first. Expect to fix
  small issues (for example provider argument names that changed in a newer 6.x release).
- It creates billable resources (NAT gateway, RDS, ElastiCache, ALB). Run
  `terraform destroy -var-file=envs/dev.tfvars` when you finish practising.
- The ECS services start with a placeholder nginx image. Replace it with your own images
  (see "Deploying your app" below).

## Prerequisites

- Terraform >= 1.11, AWS CLI v2, an AWS account and credentials with admin-level access for the first run
- Optional: a public Route 53 hosted zone if you want a custom domain

## First deploy (dev)

```bash
# 1. Remote state bucket (once per account)
cd bootstrap && terraform init && terraform apply && cd ..

# 2. Point Terraform at it
cp backend.hcl.example backend.hcl      # edit bucket name; key = dev/terraform.tfstate

# 3. Edit envs/dev.tfvars: alert_email and notification_from_email at minimum
terraform fmt -recursive
terraform init -backend-config=backend.hcl
terraform validate
terraform plan  -var-file=envs/dev.tfvars -out=tfplan
terraform apply tfplan
```

After apply:

1. Confirm the SNS alert email and the SES verification email that AWS sends you.
2. Open the `site_url` output. A 403/404 is normal until you upload a frontend.
3. Smoke test the pipeline (replace the topic ARN and addresses):

```bash
aws sns publish \
  --topic-arn "$(terraform output -raw order_events_topic_arn)" \
  --message '{"order_id":"ORD-1","customer_email":"you@example.com","customer_name":"Asha","total":"1999.00","currency":"INR","items":[{"name":"Linen shirt","qty":1}]}' \
  --message-attributes '{"event_type":{"DataType":"String","StringValue":"order_placed"}}'
```

You should receive an email within seconds. While SES is in sandbox mode, the recipient must be a verified address.

## Deploying your app

```bash
# Backend service image (immutable tag = git SHA)
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.ap-south-1.amazonaws.com
docker build -t <ecr_url_for_catalog>:$(git rev-parse --short HEAD) .
docker push <ecr_url_for_catalog>:$(git rev-parse --short HEAD)
# then register a new task definition revision with that image and update the service,
# or pass container_images in tfvars for the very first rollout

# Frontend
aws s3 sync build/ s3://$(terraform output -raw frontend_bucket) --delete
aws cloudfront create-invalidation --distribution-id $(terraform output -raw cloudfront_distribution_id) --paths "/index.html"
```

## Known trade-offs (talk about these in interviews)

| Choice | Why | What a stricter setup would do |
| --- | --- | --- |
| ALB locked by CloudFront prefix list plus secret header | Cheap, standard pattern | Add WAF on the ALB, or use VPC origins (private ALB) |
| No custom domain: CloudFront to ALB over HTTP | Works without owning a domain | Set `enable_custom_domain = true` for HTTPS end to end |
| ECS service ignores task_definition changes | CI/CD owns releases | Blue/green with CodeDeploy for canary and instant rollback |
| Single region | Simpler, cheaper | Multi-region active-passive with Aurora Global Database and Route 53 failover |
| Notifications: email only | Smallest working path | Add SMS and mobile push via Amazon SNS mobile push or AWS End User Messaging |
| No account-level baseline (CloudTrail, GuardDuty, Config) | Belongs in a landing zone, not an app stack | AWS Control Tower or Organizations with centrally managed guardrails |
| ALB and CloudFront access logs not enabled | Needs log-bucket policies that vary by region | Add a log-archive bucket and enable both |

## Layout

```
bootstrap/        remote state bucket (run once)
versions.tf       Terraform + provider versions, backend, provider config
variables.tf      all inputs, with validation
locals.tf         naming, AZs, shared values
network.tf        VPC, subnets, NAT, endpoints, flow logs
security.tf       KMS key, security groups
database.tf       RDS, DynamoDB, Valkey, S3 buckets
compute.tf        ECR, ALB, ECS, IAM, autoscaling
edge.tf           CloudFront, WAF, ACM, Route 53, bucket policies
messaging.tf      SNS, SQS, DLQs, SES, notification Lambda
observability.tf  alarms, dashboard, budget
lambda/notify/    notification worker (Python)
envs/             dev.tfvars, prod.tfvars
.github/workflows CI/CD with OIDC (no stored AWS keys)
```
