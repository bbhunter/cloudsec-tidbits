output "cloudfront_url" {
  description = "HTTP — terminal-friendly URL (scheme included)."
  value       = "http://${aws_cloudfront_distribution.portal.domain_name}/"
}

output "cloudfront_https_url" {
  description = "HTTPS — same distribution; many terminals only linkify https://"
  value       = "https://${aws_cloudfront_distribution.portal.domain_name}/"
}

output "cloudfront_distribution_id" {
  description = "Use for invalidations, e.g. aws cloudfront create-invalidation --distribution-id ..."
  value       = aws_cloudfront_distribution.portal.id
}

output "portal_alb_url" {
  description = "Main public ALB (http://) — Terraform resource aws_lb.portal."
  value       = "http://${aws_lb.portal.dns_name}/"
}

output "ops_alb_url" {
  description = "Ops ALB with http:// scheme."
  value       = "http://${aws_lb.ops.dns_name}/"
}

# Backward-compatible hostnames (no scheme) — prefer *_url outputs above.
output "portal_alb_dns" {
  value = aws_lb.portal.dns_name
}

output "ops_alb_dns" {
  value = aws_lb.ops.dns_name
}

output "portal_instance_public_ip" {
  value = aws_instance.portal.public_ip
}

output "ops_instance_public_ip" {
  value = aws_instance.ops.public_ip
}

output "iam_portal_role_name" {
  description = "IAM role on web EC2 (resource aws_iam_role.portal); sts get-caller-identity Arn should contain this."
  value       = aws_iam_role.portal.name
}

output "iam_ops_role_name" {
  description = "Expected role name on ops EC2."
  value       = aws_iam_role.ops.name
}
