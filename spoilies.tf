terraform {
  # 1.10 is the floor for use_lockfile below.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.37"
    }
  }

  # The bucket is created by scripts/bootstrap-tf-state.sh: it holds this
  # configuration's own state, so this configuration cannot create it. It lives
  # in the Spoilies account, so spinning the account out of the organization
  # carries its state along with it (§9).
  backend "s3" {
    bucket = "spoilies-tf-state"
    key    = "spoilies"
    region = "us-east-2"

    # S3-native locking; no DynamoDB table required.
    use_lockfile = true
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "alert_email" {
  # No default: like the root address, a real address is never written into the
  # repository. Supply it as $TF_VAR_alert_email.
  type        = string
  description = "Address that receives budget notifications."
}

locals {
  # Without tags the cost budget can only report one undifferentiated number,
  # and the free tier is shared across the organization (§8) — so Spoilies'
  # own spend has to be separable from everything else in the family.
  default_tags = {
    ManagedBy = "terraform"
    Repo      = "Spoilies"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.default_tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

/**************************************
* Code Bucket
**************************************/

# The name is not a free choice: github-utils' deploy-lambda.yml computes it as
# code-${account-id}-${region}-an and uploads there. Declaring the bucket as a
# `resource` keeps it owned by this account's own state, which is what keeps the
# account free of the cross-account state dependency §9 exists to avoid.

resource "aws_s3_bucket" "code" {
  bucket           = format("code-%s-%s-an", data.aws_caller_identity.current.account_id, data.aws_region.current.region)
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket = aws_s3_bucket.code.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "code" {
  bucket = aws_s3_bucket.code.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true

    # Declared to match what S3 already enforces. Leaving it out makes the
    # provider plan it away on every run, which would silently permit
    # customer-provided-key uploads that the bucket currently rejects.
    blocked_encryption_types = ["SSE-C"]
  }
}

# Every lifecycle rule carries an empty `filter {}`: that is the explicit way to
# say "apply to all objects". Omitting both filter and prefix relies on
# provider-version-specific leniency and is a recurring source of MalformedXML
# breakage on provider upgrades.
resource "aws_s3_bucket_lifecycle_configuration" "code" {
  bucket = aws_s3_bucket.code.id

  rule {
    id     = "delete-old-versions-rule"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "abort-mpu"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_versioning" "code" {
  bucket = aws_s3_bucket.code.id

  versioning_configuration {
    status = "Enabled"
  }
}

/**************************************
* Budget
**************************************/

# §6 pairs this with the reserved concurrency cap as the two controls against
# denial of wallet, and both are free.
#
# A fixed limit, because §1's ceiling is a real number and serves directly as
# one. An auto-adjusting limit reads a 3-month lookback, and this account is days
# old: the lookback would settle at $0 and alarm on the first cent.
resource "aws_budgets_budget" "monthly" {
  name              = "monthly"
  budget_type       = "COST"
  limit_amount      = "5"
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-08-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 110
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  # Forecasts are suppressed until AWS has enough history and can swing wildly,
  # so an overrun that arrives late in the month may never trigger the one above.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "code_bucket" {
  value = aws_s3_bucket.code.bucket
}
