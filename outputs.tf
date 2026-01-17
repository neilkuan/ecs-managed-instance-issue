output "cluster_name" {
  description = "ECS Cluster 名稱"
  value       = aws_ecs_cluster.main.name
}

output "cluster_arn" {
  description = "ECS Cluster ARN"
  value       = aws_ecs_cluster.main.arn
}

output "capacity_provider_name" {
  description = "Capacity Provider 名稱"
  value       = aws_ecs_capacity_provider.managed_instances.name
}

output "service_name" {
  description = "ECS Service 名稱"
  value       = aws_ecs_service.nginx.name
}

output "task_definition_arn" {
  description = "Task Definition ARN"
  value       = aws_ecs_task_definition.nginx.arn
}

output "ecs_ami_al2023_arm64" {
  description = "Amazon Linux 2023 ECS Optimized AMI (ARM64)"
  value       = nonsensitive(data.aws_ssm_parameter.ecs_ami_al2023_arm64.value)
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Subnet IDs"
  value       = module.vpc.private_subnets
}

locals {
  desired_count = 1
}