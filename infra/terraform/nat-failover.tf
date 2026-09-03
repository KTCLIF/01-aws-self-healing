data "archive_file" "nat_failover" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/../../recovery/nat_failover/handler.py"
  output_path = "${path.module}/nat-failover.zip"
}

resource "aws_iam_role" "nat_failover" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  name_prefix = "${var.project_name}-nat-failover-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "nat_failover" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  role = aws_iam_role.nat_failover[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstanceStatus", "ec2:DescribeRouteTables"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:ReplaceRoute"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.nat_failover[0].arn}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "nat_failover" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  name              = "/aws/lambda/${var.project_name}-nat-failover"
  retention_in_days = 7
}

resource "aws_lambda_function" "nat_failover" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  function_name    = "${var.project_name}-nat-failover"
  role             = aws_iam_role.nat_failover[0].arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  filename         = data.archive_file.nat_failover[0].output_path
  source_code_hash = data.archive_file.nat_failover[0].output_base64sha256
  timeout          = 15

  environment {
    variables = {
      FAILOVER_MAP = jsonencode({
        for item in flatten([
          for index in range(local.az_count) : [
            {
              key                = aws_cloudwatch_metric_alarm.nat_status[index].alarm_name
              route_table_id     = aws_route_table.app[index].id
              standby_instance   = aws_instance.nat[1 - index].id
              standby_network_if = aws_instance.nat[1 - index].primary_network_interface_id
            },
            {
              key                = aws_instance.nat[index].id
              route_table_id     = aws_route_table.app[index].id
              standby_instance   = aws_instance.nat[1 - index].id
              standby_network_if = aws_instance.nat[1 - index].primary_network_interface_id
            }
          ]
          ]) : item.key => {
          route_table_id     = item.route_table_id
          standby_instance   = item.standby_instance
          standby_network_if = item.standby_network_if
        }
      })
    }
  }

  depends_on = [aws_cloudwatch_log_group.nat_failover]
}

resource "aws_cloudwatch_event_rule" "nat_failover" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  name = "${var.project_name}-nat-failover"
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = aws_cloudwatch_metric_alarm.nat_status[*].alarm_name
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "nat_failover" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  rule = aws_cloudwatch_event_rule.nat_failover[0].name
  arn  = aws_lambda_function.nat_failover[0].arn
}

resource "aws_lambda_permission" "nat_failover" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nat_failover[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.nat_failover[0].arn
}

resource "aws_cloudwatch_event_rule" "nat_instance_state" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  name = "${var.project_name}-nat-instance-state"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      instance-id = aws_instance.nat[*].id
      state       = ["stopped", "shutting-down", "terminated"]
    }
  })
}

resource "aws_cloudwatch_event_target" "nat_instance_state" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  rule = aws_cloudwatch_event_rule.nat_instance_state[0].name
  arn  = aws_lambda_function.nat_failover[0].arn
}

resource "aws_lambda_permission" "nat_instance_state" {
  count = var.nat_mode == "instance_ha" ? 1 : 0

  statement_id  = "AllowEC2StateEvent"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nat_failover[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.nat_instance_state[0].arn
}
