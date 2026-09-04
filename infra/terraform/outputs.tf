output "availability_zones" {
  description = "The two failure domains selected for the lab."
  value       = local.azs
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}

output "nat_mode" {
  description = "Selected egress strategy; both non-none modes create billable resources on apply."
  value       = var.nat_mode
}

output "nat_failover_alarm_names" {
  description = "CloudWatch alarms that invoke route failover in instance_ha mode."
  value       = aws_cloudwatch_metric_alarm.nat_status[*].alarm_name
}

output "web_alb_url" {
  description = "HTTP probe endpoint for the AWS host-loss experiment."
  value       = var.enable_web_asg ? "http://${aws_lb.web[0].dns_name}" : null
}

output "web_asg_name" {
  value = var.enable_web_asg ? aws_autoscaling_group.web[0].name : null
}

output "web_target_group_arn" {
  value = var.enable_web_asg ? aws_lb_target_group.web[0].arn : null
}
