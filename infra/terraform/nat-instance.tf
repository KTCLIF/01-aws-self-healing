data "aws_ami" "nat" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

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

resource "aws_security_group" "nat_instance" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  name_prefix = "${var.project_name}-nat-"
  description = "Allow private app subnets to use the NAT instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "IPv4 traffic from app subnets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = aws_subnet.app[*].cidr_block
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-nat-instance" }
}

resource "aws_instance" "nat" {
  count = var.nat_mode == "instance_ha" ? local.az_count : 0

  ami                         = data.aws_ami.nat[0].id
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.public[count.index].id
  vpc_security_group_ids      = [aws_security_group.nat_instance[0].id]
  associate_public_ip_address = false
  source_dest_check           = false
  user_data                   = file("${path.module}/templates/nat-user-data.sh")

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = {
    Name = "${var.project_name}-nat-instance-${local.azs[count.index]}"
    Role = "nat-instance"
    AZ   = local.azs[count.index]
  }
}

resource "aws_eip" "nat_instance" {
  count = var.nat_mode == "instance_ha" ? local.az_count : 0

  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-instance-${local.azs[count.index]}" }
}

resource "aws_eip_association" "nat_instance" {
  count = var.nat_mode == "instance_ha" ? local.az_count : 0

  allocation_id = aws_eip.nat_instance[count.index].id
  instance_id   = aws_instance.nat[count.index].id
}

resource "aws_cloudwatch_metric_alarm" "nat_status" {
  count = var.nat_mode == "instance_ha" ? local.az_count : 0

  alarm_name          = "${var.project_name}-nat-instance-${count.index}-status"
  alarm_description   = "Detect a failed NAT instance and trigger degraded cross-AZ route failover"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = aws_instance.nat[count.index].id
  }
}
