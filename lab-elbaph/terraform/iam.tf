data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "portal_read_only" {
  statement {
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeSubnets",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "cloudfront:GetDistribution",
      "cloudfront:ListDistributions",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "portal" {
  name               = "${local.name_prefix}-portal-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy" "portal_read_only" {
  name   = "${local.name_prefix}-portal-read-only"
  role   = aws_iam_role.portal.id
  policy = data.aws_iam_policy_document.portal_read_only.json
}

resource "aws_iam_instance_profile" "portal" {
  name = "${local.name_prefix}-portal-profile"
  role = aws_iam_role.portal.name
}

resource "aws_iam_role" "ops" {
  name               = "${local.name_prefix}-ops-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# Same read-only ELB/EC2/CloudFront enumeration as the web instance role (post-exploitation on either host).
resource "aws_iam_role_policy" "ops_read_only" {
  name   = "${local.name_prefix}-ops-read-only"
  role   = aws_iam_role.ops.id
  policy = data.aws_iam_policy_document.portal_read_only.json
}

resource "aws_iam_instance_profile" "ops" {
  name = "${local.name_prefix}-ops-profile"
  role = aws_iam_role.ops.name
}
