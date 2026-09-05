#!/usr/bin/env bash
#
# Creates the Terraform state bucket for Spoilies.
#
# This is the one piece of the estate that cannot be a Terraform resource: it is
# where Terraform's own state lives, so the configuration that stores state there
# cannot also create it. Everything else in the account is in spoilies.tf.
#
# Idempotent — safe to re-run. Settings match the conventions in the
# AmazonWebServices repo: versioning, public access fully blocked, KMS at rest
# with a bucket key, incomplete uploads aborted after 7 days, and superseded
# versions expired after 30 days.

set -euo pipefail

BUCKET="${BUCKET:-spoilies-tf-state}"
REGION="${REGION:-us-east-2}"
PROFILE="${AWS_PROFILE:-spoilies}"

aws() { command aws --profile "$PROFILE" --region "$REGION" "$@"; }

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    echo "Bucket $BUCKET already exists; reconciling settings."
else
    echo "Creating $BUCKET in $REGION."
    aws s3api create-bucket \
        --bucket "$BUCKET" \
        --create-bucket-configuration "LocationConstraint=$REGION"
fi

# Versioning first: it is what makes a corrupted or truncated state file
# recoverable, and the lifecycle rule below assumes it is on.
aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"},
            "BucketKeyEnabled": true
        }]
    }'

aws s3api put-bucket-lifecycle-configuration \
    --bucket "$BUCKET" \
    --lifecycle-configuration '{
        "Rules": [
            {
                "ID": "delete-old-versions-rule",
                "Status": "Enabled",
                "Filter": {},
                "NoncurrentVersionExpiration": {"NoncurrentDays": 30}
            },
            {
                "ID": "abort-mpu",
                "Status": "Enabled",
                "Filter": {},
                "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
            }
        ]
    }'

echo "Done. Terraform backend bucket: s3://$BUCKET (region $REGION)."
