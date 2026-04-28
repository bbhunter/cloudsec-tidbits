data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

locals {
  geo_blocked_html = templatefile("${path.module}/templates/geo-blocked.html.tftpl", {
    public_alb_dns = aws_lb.portal.dns_name
  })
  app_files = {
    "go.mod"                           = filebase64("${path.module}/../app/go.mod")
    "web.go"                           = filebase64("${path.module}/../app/web.go")
    "frontend/index.html"              = filebase64("${path.module}/../app/frontend/index.html")
    "frontend/diagnostics.html"        = filebase64("${path.module}/../app/frontend/diagnostics.html")
    "frontend/ops.html"                = filebase64("${path.module}/../app/frontend/ops.html")
    "frontend/errors/geo-blocked.html" = base64encode(local.geo_blocked_html)
  }
}

resource "aws_instance" "portal" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.portal_instance.id]
  iam_instance_profile        = aws_iam_instance_profile.portal.name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "optional"
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/userdata/app.sh.tftpl", {
    app_mode     = "web"
    app_files    = local.app_files
    listen_port  = "80"
    ops_link_url = "http://${aws_lb.ops.dns_name}"
  }))

  tags = {
    Name = "${local.name_prefix}-portal"
  }
}

resource "aws_instance" "ops" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public_b.id
  vpc_security_group_ids      = [aws_security_group.ops_instance.id]
  iam_instance_profile        = aws_iam_instance_profile.ops.name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/userdata/app.sh.tftpl", {
    app_mode     = "ops"
    app_files    = local.app_files
    listen_port  = "80"
    ops_link_url = "http://${aws_lb.ops.dns_name}"
  }))

  tags = {
    Name = "${local.name_prefix}-ops"
  }
}
