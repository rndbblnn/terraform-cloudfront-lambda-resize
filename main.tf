terraform {
  required_version = ">= 1.2.0"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 4.16.0"
    }
  }
}
locals {
  name_prefix = "image-resize-test"
  default_tags = {
    Terraform = "true",
  }
}
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = local.default_tags
  }
}
provider "aws" { // needed for Lambda Edge deployment as it must be in us-east-1 region
  alias = "global"
  region = "us-east-1"
  default_tags {
    tags = local.default_tags
  }
}

//

locals {
  release_zip_path = "${path.module}/function/release.zip" // path to release zip
}
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"]
    }
  }
}
data "aws_iam_policy" "basic_execution_role" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
// provide required accesses to S3 for lambda
data "aws_iam_policy_document" "s3_access" {
  statement {
    actions = ["s3:ListBucket"]
    resources = [aws_s3_bucket.main.arn]
  }
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.main.arn}/*"]
  }
}
resource "aws_iam_policy" "s3_access" {
  name = "${local.name_prefix}-image-resize-lambda-s3-access"
  policy = data.aws_iam_policy_document.s3_access.json
}
resource "aws_iam_role" "image_resize_lambda" {
  name = "${local.name_prefix}-image-resize-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  managed_policy_arns = [
    data.aws_iam_policy.basic_execution_role.arn,
    aws_iam_policy.s3_access.arn,
  ]
}
resource "aws_lambda_function" "image_resize" {
  provider = aws.global // picking global aws provider to deploy it in us-east-1 region
  function_name = "${local.name_prefix}-image-resize"
  runtime = "nodejs16.x"
  architectures = ["x86_64"]
  memory_size = 2048
  timeout = 10
  handler = "dist/index.handler"
  filename = local.release_zip_path
  source_code_hash = filebase64sha256(local.release_zip_path)
  role = aws_iam_role.image_resize_lambda.arn
  publish = true
}

//

resource "aws_s3_bucket" "main" {
  bucket = "${local.name_prefix}-cdn"
}
resource "aws_s3_bucket_acl" "main" {
  bucket = aws_s3_bucket.main.id
  acl = "private"
}
resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id
  block_public_acls = true
  ignore_public_acls = true
  block_public_policy = true
  restrict_public_buckets = true
}
resource "aws_cloudfront_origin_access_identity" "main" {
  comment = "access-to-${aws_s3_bucket.main.bucket}"
}
data "aws_iam_policy_document" "main" {
  statement {
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.main.arn}/*"]
    principals {
      type = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.main.iam_arn]
    }
  }
}
resource "aws_s3_bucket_policy" "main" {
  bucket = aws_s3_bucket.main.id
  policy = data.aws_iam_policy_document.main.json
}
resource "aws_cloudfront_distribution" "main" {
  comment = aws_s3_bucket.main.bucket
  enabled = true
  is_ipv6_enabled = true
  price_class = "PriceClass_100"
  origin {
    domain_name = aws_s3_bucket.main.bucket_regional_domain_name
    origin_id = aws_s3_bucket.main.id
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.main.cloudfront_access_identity_path
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  default_cache_behavior {
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods = ["GET", "HEAD"]
    compress = true
    target_origin_id = aws_s3_bucket.main.id
    viewer_protocol_policy = "redirect-to-https"
    min_ttl = 0
    default_ttl = 3600
    max_ttl = 604800
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
    lambda_function_association {
      event_type = "origin-request"
      lambda_arn = aws_lambda_function.image_resize.qualified_arn
    }
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}