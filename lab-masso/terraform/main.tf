# ---------------------------------------------------------------------------
# Random Cats Extractor™ - Multi-SSO Identity Crisis Lab
# CloudSec Tidbits S2, Lab 1
#
# Deploy: cd terraform/ && bash deploy.sh
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for all lab resources. Override with -var='aws_region=...' or TF_VAR_aws_region when different from default."
  default     = "us-east-1"
}

provider "aws" {
  region = var.aws_region
}

locals {
  region    = var.aws_region
  app_image = "public.ecr.aws/s3v0n4c3/cloudsectidbit-caats:latest"
  tags = {
    "lab" = "demolab1-random-cats"
  }
  timestamp = timestamp()
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(local.tags, { Name = "demolab1-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "demolab1-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/20"
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "demolab1-subnet" })
}

resource "aws_route" "default" {
  route_table_id         = aws_vpc.main.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_security_group" "public" {
  name        = "demolab1-sg-${random_string.suffix.result}"
  vpc_id      = aws_vpc.main.id
  description = "HTTPS in + all out"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS inbound"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "demolab1-sg" })
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_iam_role" "ecs_execution" {
  name = "demolab1-ecs-exec-${random_string.suffix.result}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_logging" {
  name = "demolab1-ecs-logging"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "ecs_task" {
  name = "demolab1-ecs-task-${random_string.suffix.result}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "ecs_cognito" {
  name = "demolab1-ecs-cognito"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["cognito-idp:*"]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "lambda" {
  name = "demolab1-lambda-${random_string.suffix.result}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_cognito" {
  name = "demolab1-lambda-cognito"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["cognito-idp:*"]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_cognito_user_pool" "main" {
  name = "demolab1-user-pool-${random_string.suffix.result}"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  schema {
    name                = "tenantID"
    attribute_data_type = "String"
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  schema {
    name                = "isOrgAdmin"
    attribute_data_type = "String"
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  schema {
    name                = "orgName"
    attribute_data_type = "String"
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  schema {
    name                = "primaryEmail"
    attribute_data_type = "String"
    mutable             = true
    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  lambda_config {
    pre_sign_up         = aws_lambda_function.pre_signup.arn
    pre_authentication  = aws_lambda_function.pre_authentication.arn
    post_confirmation   = aws_lambda_function.jit_provisioning.arn # Used for JIT OIDC logic
  }

  password_policy {
    minimum_length    = 6
    require_lowercase = false
    require_numbers   = false
    require_symbols   = false
    require_uppercase = false
  }

  tags = local.tags
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "random-cats-${random_string.suffix.result}"
  user_pool_id = aws_cognito_user_pool.main.id
}

resource "aws_cognito_user_pool_client" "app" {
  name                                 = "random-cats-app"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = false
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  callback_urls                        = ["https://localhost/callback"]
  logout_urls                          = ["https://localhost/"]
  supported_identity_providers         = ["COGNITO"]
  allowed_oauth_flows_user_pool_client = true

  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_PASSWORD_AUTH", "ALLOW_ADMIN_USER_PASSWORD_AUTH"]

  read_attributes  = ["email", "name", "custom:tenantID", "custom:isOrgAdmin", "custom:orgName", "custom:primaryEmail"]
  # write_attributes intentionally excludes custom:tenantID, custom:isOrgAdmin, custom:orgName, custom:primaryEmail
  # to block direct UpdateUserAttributes tampering (Cognito mass-assignment via access token).
  # Cross-tenant pollution is still possible via OIDC AttributeMapping → JIT Lambda (admin API path).
  write_attributes = ["email", "name"]
}

resource "aws_lambda_function" "pre_signup" {
  filename         = data.archive_file.pre_signup.output_path
  function_name    = "demolab1-pre-signup-${random_string.suffix.result}"
  role             = aws_iam_role.lambda.arn
  handler          = "pre_signup.handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.pre_signup.output_base64sha256
  timeout          = 60
  tags             = local.tags
}

resource "aws_lambda_function" "pre_authentication" {
  filename         = data.archive_file.pre_authentication.output_path
  function_name    = "demolab1-pre-auth-${random_string.suffix.result}"
  role             = aws_iam_role.lambda.arn
  handler          = "pre_authentication.handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.pre_authentication.output_base64sha256
  timeout          = 60
  tags             = local.tags
}

resource "aws_lambda_function" "jit_provisioning" {
  filename         = data.archive_file.jit_provisioning.output_path
  function_name    = "demolab1-jit-${random_string.suffix.result}"
  role             = aws_iam_role.lambda.arn
  handler          = "jit_provisioning.handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.jit_provisioning.output_base64sha256
  timeout          = 60
  tags             = local.tags
}

data "archive_file" "pre_signup" {
  type        = "zip"
  source_file = "../lambdas/pre_signup.py"
  output_path = "pre_signup.zip"
}

data "archive_file" "pre_authentication" {
  type        = "zip"
  source_file = "../lambdas/pre_authentication.py"
  output_path = "pre_authentication.zip"
}

data "archive_file" "jit_provisioning" {
  type        = "zip"
  source_file = "../lambdas/jit_provisioning.py"
  output_path = "jit_provisioning.zip"
}

resource "aws_lambda_permission" "pre_signup" {
  statement_id  = "AllowCognito"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_signup.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}

resource "aws_lambda_permission" "pre_authentication" {
  statement_id  = "AllowCognito"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_authentication.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}

resource "aws_lambda_permission" "jit_provisioning" {
  statement_id  = "AllowCognito"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.jit_provisioning.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}

resource "aws_ecs_cluster" "main" {
  name = "demolab1-cluster-${random_string.suffix.result}"
  tags = local.tags
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/demolab1-app"
  retention_in_days = 1
}

resource "aws_ecs_task_definition" "app" {
  family                   = "demolab1-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  task_role_arn            = aws_iam_role.ecs_task.arn
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions    = <<DEFINITION
    [
        {
            "image": "${local.app_image}",
            "name": "demolab1-app",
            "essential": true,
            "environment": [
                {"name": "REGION", "value": "${var.aws_region}"},
                {"name": "CLIENT_ID", "value": "${aws_cognito_user_pool_client.app.id}"},
                {"name": "USERPOOL_ID", "value": "${aws_cognito_user_pool.main.id}"},
                {"name": "COGNITO_DOMAIN", "value": "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"},
                {"name": "DEPLOY_TIMESTAMP", "value": "${local.timestamp}"}
            ],
            "portMappings":[
                {
                    "containerPort" : 443,
                    "hostPort"      : 443
                }
            ],
            "memory"    : 512,
            "cpu"       : 256,
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "${aws_cloudwatch_log_group.ecs.name}",
                    "awslogs-region": "${var.aws_region}",
                    "awslogs-stream-prefix": "app"
                }
            }
        }
    ]
  DEFINITION

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = local.tags
}

resource "aws_ecs_service" "app" {
  name            = "demolab1-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    assign_public_ip = true
    security_groups  = [aws_security_group.public.id]
    subnets          = [aws_subnet.public.id]
  }

  tags = local.tags
}

output "user_pool_id" { value = aws_cognito_user_pool.main.id }
output "app_client_id" { value = aws_cognito_user_pool_client.app.id }
output "cognito_hosted_ui_domain" { value = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com" }
output "ecs_cluster_name" { value = aws_ecs_cluster.main.name }
output "region" { value = var.aws_region }
