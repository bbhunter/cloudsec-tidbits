resource "aws_security_group" "portal_alb" {
  name        = "${local.name_prefix}-portal-alb-sg"
  description = "Public HTTP access to the main public ALB (Terraform: portal)"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ops_alb" {
  name        = "${local.name_prefix}-ops-alb-sg"
  description = "Public HTTP access to the ops ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "portal_instance" {
  name        = "${local.name_prefix}-portal-instance-sg"
  description = "Web instance with intentional direct reachability"
  vpc_id      = aws_vpc.main.id

  revoke_rules_on_delete = true

  timeouts {
    delete = "45m"
  }

  # Single IPv4 rule: ALB→target traffic uses ALB ENI private IPs; direct hits use public IP — both covered.
  # Avoids ingress rules that reference other security groups (cleaner teardown, same effective access).
  ingress {
    description = "HTTP (ALB forwarded traffic and intentional direct exposure)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ops_instance" {
  name        = "${local.name_prefix}-ops-instance-sg"
  description = "Ops app: ALB paths plus intentional direct HTTP from the internet"
  vpc_id      = aws_vpc.main.id

  revoke_rules_on_delete = true

  timeouts {
    delete = "45m"
  }

  ingress {
    description = "HTTP (ALB forwarded traffic and intentional direct exposure)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
