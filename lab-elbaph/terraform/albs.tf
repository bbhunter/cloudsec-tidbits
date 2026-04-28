resource "aws_lb" "portal" {
  name                       = "${local.name_prefix}-portal"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.portal_alb.id]
  subnets                    = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  desync_mitigation_mode     = "monitor"
  drop_invalid_header_fields = false
}

resource "aws_lb" "ops" {
  name                   = "${local.name_prefix}-ops"
  internal               = false
  load_balancer_type     = "application"
  security_groups        = [aws_security_group.ops_alb.id]
  subnets                = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  desync_mitigation_mode = "monitor"
}

resource "aws_lb_target_group" "portal" {
  name        = "${local.name_prefix}-portal-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path = "/healthz"
  }
}

resource "aws_lb_target_group" "ops" {
  name        = "${local.name_prefix}-ops-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path = "/healthz"
  }
}

resource "aws_lb_target_group" "ops_bypass" {
  name        = "${local.name_prefix}-ops-bypass"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path = "/healthz"
  }
}

resource "aws_lb_target_group_attachment" "portal" {
  target_group_arn = aws_lb_target_group.portal.arn
  target_id        = aws_instance.portal.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "ops" {
  target_group_arn = aws_lb_target_group.ops.arn
  target_id        = aws_instance.ops.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "ops_bypass" {
  target_group_arn = aws_lb_target_group.ops_bypass.arn
  target_id        = aws_instance.ops.id
  port             = 80
}

resource "aws_lb_listener" "portal_http_redirect" {
  load_balancer_arn = aws_lb.portal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "portal" {
  load_balancer_arn = aws_lb.portal.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.portal.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.portal.arn
  }
}

# Hostname-based ops routing (e.g. curl -H "Host: svc.ops.internal" http://<portal-alb>/).
resource "aws_lb_listener_rule" "portal_ops_host_header" {
  listener_arn = aws_lb_listener.portal.arn
  priority     = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ops_bypass.arn
  }

  condition {
    host_header {
      values = ["svc.ops.internal"]
    }
  }
}

resource "aws_lb_listener_rule" "portal_ops_bypass" {
  listener_arn = aws_lb_listener.portal.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ops_bypass.arn
  }

  condition {
    path_pattern {
      values = ["/ops", "/ops/*"]
    }
  }
}

# Vulnerability: Shadowing — lower priority number is evaluated first.
# Broad /* forwards to the portal without auth; the OIDC rule below never runs for matched traffic.
resource "aws_lb_listener_rule" "portal_shadowing_catchall" {
  listener_arn = aws_lb_listener.portal.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.portal.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

# Intended: authenticate all paths then forward to the portal (shadowed by priority 20).
resource "aws_lb_listener_rule" "portal_auth_catchall" {
  listener_arn = aws_lb_listener.portal.arn
  priority     = 30

  action {
    type = "authenticate-oidc"

    authenticate_oidc {
      authorization_endpoint     = "https://example.com/auth"
      client_id                  = "client-id"
      client_secret              = "client-secret"
      issuer                     = "https://example.com"
      token_endpoint             = "https://example.com/token"
      user_info_endpoint         = "https://example.com/userinfo"
      on_unauthenticated_request = "authenticate"
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.portal.arn
  }

  condition {
    path_pattern {
      values = ["/admin/*"]
    }
  }
}

resource "aws_lb_listener" "ops" {
  load_balancer_arn = aws_lb.ops.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "You are not allowed to access the operations endpoint from this network."
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "ops_office_only" {
  listener_arn = aws_lb_listener.ops.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ops.arn
  }

  condition {
    source_ip {
      values = [var.office_cidr]
    }
  }
}

