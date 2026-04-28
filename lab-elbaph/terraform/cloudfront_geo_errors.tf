data "aws_caller_identity" "current" {}

resource "aws_cloudfront_origin_access_control" "geo_errors" {
  name                              = "${var.name_prefix}-geo-errors-oac"
  description                       = "OAC for geo-blocked HTML object"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket" "cf_geo_errors" {
  bucket = "${var.name_prefix}-cf-geo-errors-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.name_prefix}-cf-geo-errors"
  }
}

resource "aws_s3_bucket_public_access_block" "cf_geo_errors" {
  bucket = aws_s3_bucket.cf_geo_errors.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "geo_blocked" {
  bucket       = aws_s3_bucket.cf_geo_errors.id
  key          = "errors/geo-blocked.html"
  content      = local.geo_blocked_html
  content_type = "text/html; charset=utf-8"
}

data "aws_iam_policy_document" "cf_geo_errors" {
  statement {
    sid    = "AllowCloudFrontReadGeoPage"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.cf_geo_errors.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudfront_distribution.portal.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "cf_geo_errors" {
  bucket = aws_s3_bucket.cf_geo_errors.id
  policy = data.aws_iam_policy_document.cf_geo_errors.json

  depends_on = [aws_cloudfront_distribution.portal]
}
