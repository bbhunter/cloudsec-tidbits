resource "aws_cloudfront_distribution" "portal" {
  enabled = true

  origin {
    domain_name = aws_lb.portal.dns_name
    origin_id   = "portal-alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    domain_name              = aws_s3_bucket.cf_geo_errors.bucket_regional_domain_name
    origin_id                = "geo-errors-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.geo_errors.id
  }

  ordered_cache_behavior {
    path_pattern     = "/errors/geo-blocked.html"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "geo-errors-s3"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 300
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "portal-alb-origin"

    forwarded_values {
      query_string = true

      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 60
    max_ttl                = 300
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = var.allowed_country_codes
    }
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/errors/geo-blocked.html"
    error_caching_min_ttl = 0
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
