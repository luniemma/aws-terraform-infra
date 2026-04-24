################################################################################
# EC2 Module
################################################################################

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

################################################################################
# Security Group
################################################################################

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-${var.environment}-ec2-sg"
  description = "Security group for EC2 instances"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = length(var.allowed_ssh_cidrs) > 0 ? 1 : 0

  security_group_id = aws_security_group.ec2.id
  description       = "Allow SSH from trusted IPs"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = var.allowed_ssh_cidrs[0]
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.ec2.id
  description       = "Allow HTTP"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.ec2.id
  description       = "Allow HTTPS"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.ec2.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

################################################################################
# IAM Role for EC2 (SSM + CloudWatch)
################################################################################

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_name}-${var.environment}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-profile"
  role = aws_iam_role.ec2.name
}

################################################################################
# Key Pair
################################################################################

resource "aws_key_pair" "main" {
  count = var.public_key_path != "" ? 1 : 0

  key_name   = "${var.project_name}-${var.environment}-key"
  public_key = file(var.public_key_path)

  tags = {
    Name = "${var.project_name}-${var.environment}-key"
  }
}

################################################################################
# Launch Template
################################################################################

resource "aws_launch_template" "main" {
  name_prefix   = "${var.project_name}-${var.environment}-"
  image_id      = coalesce(var.ami_id, data.aws_ami.amazon_linux_2023.id)
  instance_type = var.instance_type

  key_name = var.public_key_path != "" ? aws_key_pair.main[0].key_name : null

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  vpc_security_group_ids = [aws_security_group.ec2.id]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = var.root_volume_type
      encrypted             = true
      delete_on_termination = true
    }
  }

  dynamic "block_device_mappings" {
    for_each = var.additional_ebs_volumes
    content {
      device_name = block_device_mappings.value.device_name

      ebs {
        volume_size           = block_device_mappings.value.volume_size
        volume_type           = block_device_mappings.value.volume_type
        encrypted             = true
        delete_on_termination = true
      }
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  user_data = base64encode(templatefile("${path.root}/userdata.sh", {
    project_name = var.project_name
    environment  = var.environment
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-${var.environment}-ec2"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.project_name}-${var.environment}-volume"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# EC2 Instances
################################################################################

resource "aws_instance" "main" {
  count = var.instance_count

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  subnet_id = var.ec2_in_public_subnet ? var.public_subnet_ids[count.index % length(var.public_subnet_ids)] : var.private_subnet_ids[count.index % length(var.private_subnet_ids)]

  tags = {
    Name  = "${var.project_name}-${var.environment}-ec2-${count.index + 1}"
    Index = tostring(count.index + 1)
  }
}

################################################################################
# Elastic IP
################################################################################

resource "aws_eip" "ec2" {
  count  = var.ec2_in_public_subnet && var.assign_eip ? var.instance_count : 0
  domain = "vpc"

  instance = aws_instance.main[count.index].id

  tags = {
    Name = "${var.project_name}-${var.environment}-eip-${count.index + 1}"
  }
}

################################################################################
# CloudWatch Alarms
################################################################################

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count = var.instance_count

  alarm_name          = "${var.project_name}-${var.environment}-cpu-high-${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  alarm_description   = "EC2 CPU utilization is too high"
  alarm_actions       = var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : []

  dimensions = {
    InstanceId = aws_instance.main[count.index].id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-cpu-alarm-${count.index + 1}"
  }
}
