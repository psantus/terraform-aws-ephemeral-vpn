# ---------------------------------------------------------------------------
# Static web UI: S3 (private) + CloudFront (OAC). A "secret key" form that
# calls the Lambda Function URL. config.js is generated from the Function URL.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "web" {
  bucket_prefix = "${local.name}-web-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${local.name}-web-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- Optional custom domain (e.g. vpn.example.com) ---
locals {
  custom_domain_enabled = var.dns_name != "" && var.dns_hosted_zone_name != ""
  custom_fqdn           = local.custom_domain_enabled ? "${var.dns_name}.${var.dns_hosted_zone_name}" : ""
}

data "aws_route53_zone" "web" {
  count        = local.custom_domain_enabled ? 1 : 0
  name         = var.dns_hosted_zone_name
  private_zone = false
}

# CloudFront requires the cert in us-east-1 (set via the resource region attr).
resource "aws_acm_certificate" "web" {
  count             = local.custom_domain_enabled ? 1 : 0
  region            = "us-east-1"
  domain_name       = local.custom_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "web_cert_validation" {
  for_each = local.custom_domain_enabled ? {
    for dvo in aws_acm_certificate.web[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id = data.aws_route53_zone.web[0].zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "web" {
  count                   = local.custom_domain_enabled ? 1 : 0
  region                  = "us-east-1"
  certificate_arn         = aws_acm_certificate.web[0].arn
  validation_record_fqdns = [for r in aws_route53_record.web_cert_validation : r.fqdn]
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${var.app_title} toggle UI"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "s3-web"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-web"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    min_ttl     = 0
    default_ttl = 60
    max_ttl     = 300
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  aliases = local.custom_domain_enabled ? [local.custom_fqdn] : []

  viewer_certificate {
    cloudfront_default_certificate = local.custom_domain_enabled ? null : true
    acm_certificate_arn            = local.custom_domain_enabled ? aws_acm_certificate_validation.web[0].certificate_arn : null
    ssl_support_method             = local.custom_domain_enabled ? "sni-only" : null
    minimum_protocol_version       = local.custom_domain_enabled ? "TLSv1.2_2021" : "TLSv1"
  }

  tags = { Name = "${local.name}-web" }
}

# Alias record: custom_fqdn -> CloudFront
resource "aws_route53_record" "web_alias" {
  count   = local.custom_domain_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.web[0].zone_id
  name    = local.custom_fqdn
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.web.domain_name
    zone_id                = aws_cloudfront_distribution.web.hosted_zone_id
    evaluate_target_health = false
  }
}

# Allow only this CloudFront distribution to read the bucket.
data "aws_iam_policy_document" "web_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web_bucket.json
}

# --- Objects ---
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.web.id
  key          = "index.html"
  source       = "${path.module}/frontend/index.html"
  etag         = filemd5("${path.module}/frontend/index.html")
  content_type = "text/html"
}

resource "aws_s3_object" "appjs" {
  bucket       = aws_s3_bucket.web.id
  key          = "app.js"
  source       = "${path.module}/frontend/app.js"
  etag         = filemd5("${path.module}/frontend/app.js")
  content_type = "application/javascript"
}

# config.js is generated from the Function URL so the page knows where to call.
resource "aws_s3_object" "configjs" {
  bucket       = aws_s3_bucket.web.id
  key          = "config.js"
  content      = <<-JS
    window.CONFIG = {
      APP_TITLE: "${var.app_title}",
      API_URL: "${aws_apigatewayv2_api.toggle.api_endpoint}/vpn",
      COGNITO_DOMAIN: "https://${var.cognito_domain_prefix}.auth.${var.region}.amazoncognito.com",
      COGNITO_CLIENT_ID: "${aws_cognito_user_pool_client.web.id}",
      REDIRECT_URI: "${local.web_origin}/",
      EXPECTED_ASSOC_SEC: ${var.expected_assoc_sec}
    };
  JS
  content_type = "application/javascript"
  etag         = md5("${var.app_title}${aws_apigatewayv2_api.toggle.api_endpoint}${aws_cognito_user_pool_client.web.id}${var.expected_assoc_sec}")
}

# Invalidate CloudFront whenever any frontend object changes, so the new files
# serve immediately (default TTL would otherwise cache the old ones).
resource "null_resource" "invalidate" {
  triggers = {
    index  = filemd5("${path.module}/frontend/index.html")
    appjs  = filemd5("${path.module}/frontend/app.js")
    config = md5("${var.app_title}${aws_apigatewayv2_api.toggle.api_endpoint}${aws_cognito_user_pool_client.web.id}${var.expected_assoc_sec}${local.web_origin}")
  }

  provisioner "local-exec" {
    command = "aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.web.id} --paths '/*' --region ${var.region}"
  }

  depends_on = [aws_s3_object.index, aws_s3_object.appjs, aws_s3_object.configjs]
}

output "web_url" {
  description = "URL of the VPN toggle web UI (custom domain if configured)"
  value       = local.web_origin
}
