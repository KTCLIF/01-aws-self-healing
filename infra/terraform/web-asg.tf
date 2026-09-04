data "aws_ami" "web" {
  count = var.enable_web_asg ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_security_group" "web_alb" {
  count = var.enable_web_asg ? 1 : 0

  name_prefix = "${var.project_name}-web-alb-"
  description = "Public HTTP entry point for the web availability experiment"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-web-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "web_alb_http" {
  for_each = var.enable_web_asg ? toset(var.web_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.web_alb[0].id
  description       = "HTTP probe traffic"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_security_group" "web_instance" {
  count = var.enable_web_asg ? 1 : 0

  name_prefix = "${var.project_name}-web-instance-"
  description = "Only the experiment ALB can reach web instances"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-web-instance" }
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  count = var.enable_web_asg ? 1 : 0

  security_group_id            = aws_security_group.web_alb[0].id
  description                  = "ALB traffic and health checks to web instances"
  referenced_security_group_id = aws_security_group.web_instance[0].id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  count = var.enable_web_asg ? 1 : 0

  security_group_id            = aws_security_group.web_instance[0].id
  description                  = "Application traffic from the ALB only"
  referenced_security_group_id = aws_security_group.web_alb[0].id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_lb" "web" {
  count = var.enable_web_asg ? 1 : 0

  name               = "${substr(var.project_name, 0, 20)}-web"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_alb[0].id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = { Name = "${var.project_name}-web" }
}

resource "aws_lb_target_group" "web" {
  count = var.enable_web_asg ? 1 : 0

  name        = "${substr(var.project_name, 0, 20)}-web"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  deregistration_delay = 15

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 5
    timeout             = 2
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.project_name}-web" }
}

resource "aws_lb_listener" "web_http" {
  count = var.enable_web_asg ? 1 : 0

  load_balancer_arn = aws_lb.web[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web[0].arn
  }
}

resource "aws_launch_template" "web" {
  count = var.enable_web_asg ? 1 : 0

  name_prefix   = "${var.project_name}-web-"
  image_id      = data.aws_ami.web[0].id
  instance_type = var.web_instance_type
  user_data     = base64encode(file("${path.module}/templates/web-user-data.sh"))

  vpc_security_group_ids = [aws_security_group.web_instance[0].id]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted             = true
      volume_size           = 8
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-web-asg"
      Role = "stateless-web"
    }
  }

  update_default_version = true
}

resource "aws_autoscaling_group" "web" {
  count = var.enable_web_asg ? 1 : 0

  name_prefix         = "${var.project_name}-web-"
  min_size            = 2
  max_size            = 2
  desired_capacity    = 2
  vpc_zone_identifier = aws_subnet.app[*].id
  target_group_arns   = [aws_lb_target_group.web[0].arn]

  health_check_type         = "ELB"
  health_check_grace_period = 90

  launch_template {
    id      = aws_launch_template.web[0].id
    version = "$Latest"
  }

  instance_maintenance_policy {
    min_healthy_percentage = 50
    max_healthy_percentage = 100
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-web-asg"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
