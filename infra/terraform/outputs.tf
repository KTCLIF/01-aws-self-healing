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
  description = "Selected egress strategy; per_az creates billable resources on apply."
  value       = var.nat_mode
}
