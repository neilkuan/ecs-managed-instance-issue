terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.25.0"
    }
  }
}

variable "region" {
  type = string
  default = "ap-east-2"
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "6.5.1"
  name = "managed-instances-vpc"
  cidr = "10.0.0.0/16"
  azs = data.aws_availability_zones.available.names
  one_nat_gateway_per_az = false
  enable_nat_gateway = true
  single_nat_gateway = true
  nat_gateway_tags = {
    Name = "managed-instances-nat-gateway"
  }
  private_subnets = [for az in data.aws_availability_zones.available.names : cidrsubnet("10.0.0.0/16", 8, index(data.aws_availability_zones.available.names, az))]
  public_subnets = [for az in data.aws_availability_zones.available.names : cidrsubnet("10.0.0.0/16", 8, index(data.aws_availability_zones.available.names, az) + 3)]
}

# 取得 Amazon Linux 2023 ECS Optimized AMI (ARM64 for t4g)
data "aws_ssm_parameter" "ecs_ami_al2023_arm64" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

resource "aws_security_group" "ecs_instances" {
  name        = "ecs-managed-instances-sg"
  description = "Security group for ECS Managed Instances"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-managed-instances-sg"
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "ecs-tasks-sg"
  description = "Security group for ECS Tasks"
  vpc_id      = module.vpc.vpc_id

  # ingress {
  #   from_port   = 80
  #   to_port     = 80
  #   protocol    = "tcp"
  #   cidr_blocks = ["0.0.0.0/0"]
  # }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-tasks-sg"
  }
}
resource "aws_iam_role" "ecs_infrastructure_role" {
  name = "ecsInfrastructureRole-neil"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "ecsInfrastructureRole-neil"
  }
}

resource "aws_iam_role" "ecs_instance_role" {
  name = "ecsInstanceRole-neil"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "ecsInstanceRole-neil"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure_role_policy" {
  role       = aws_iam_role.ecs_infrastructure_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForManagedInstances"
  depends_on = [
    module.vpc,
  ]
}

resource "aws_iam_role_policy_attachment" "ecs_instance_role_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  depends_on = [
    module.vpc,
  ]
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecsInstanceProfile"
  role = aws_iam_role.ecs_instance_role.name
  depends_on = [
    module.vpc,
  ]
}

# Task Execution Role
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole-neil"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "ecsTaskExecutionRole-neil"
  }
  depends_on = [
    module.vpc,
  ]
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  depends_on = [
    module.vpc,
  ]
}
data "aws_iam_policy_document" "ecs_task_and_task_execution_policy" {
  statement {
    sid    = "AllowExecuteCommandFromAgent"
    effect = "Allow"
    actions = [
      "ssmmessages:OpenDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:CreateDataChannel",  
      "ssmmessages:CreateControlChannel"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecs_task_and_task_execution_policy" {
  name   = "allow-ssm-ecs-policy"
  policy = data.aws_iam_policy_document.ecs_task_and_task_execution_policy.json
  depends_on = [
    module.vpc,
  ]
  lifecycle {
    ignore_changes = [ 
      description
     ]
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy_ssm" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_task_and_task_execution_policy.arn
  depends_on = [
    module.vpc,
  ]
}


resource "aws_service_discovery_http_namespace" "service_discovery_namespace" {
  name = "neil-lab"
  
  tags = {
    Name = "service-discovery-namespace"
  }
  depends_on = [
    module.vpc,
  ]
}

# =============================================================================
# ECS Cluster
# =============================================================================
resource "aws_ecs_cluster" "main" {
  name = "managed-instances-cluster"
  
  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.service_discovery_namespace.arn
  }

  tags = {
    Name        = "managed-instances-cluster"
    Environment = "test"
  }
  configuration {
    execute_command_configuration {
      log_configuration {
        cloud_watch_log_group_name = "/ecs/nginx-managed-instances"
      }
      logging = "OVERRIDE"
    }
  }
  depends_on = [
    module.vpc,
  ]
}

# =============================================================================
# ECS Capacity Provider (Managed Instances)
# 根據 PR #44509 的新參數結構
# =============================================================================

resource "aws_ecs_capacity_provider" "managed_instances" {
  depends_on = [ 
    module.vpc,
  ]
  name = "managed-instances-cp"

  # 指定關聯的 Cluster (PR #44509 新增)
  cluster = aws_ecs_cluster.main.name

  # Managed Instances Provider 配置 (PR #44509 新增)
  managed_instances_provider {
    infrastructure_role_arn = aws_iam_role.ecs_infrastructure_role.arn

    instance_launch_template {
      ec2_instance_profile_arn = aws_iam_instance_profile.ecs_instance_profile.arn
      # Instance Requirements - 使用 attribute-based selection
      # 選擇 ARM 架構、2 vCPU、4GB memory 的 instance (如 t4g.medium)
      instance_requirements {
        # 使用 attribute-based selection (不要同時指定 allowed_instance_types)
        vcpu_count {
          min = 1
          max = 4
        }
        memory_mib {
          min = 1 * 1024
          max = 4 * 1024
        }
        allowed_instance_types = ["t4g.*", "c7g.*", "m7g.*"]
        cpu_manufacturers = ["amazon-web-services", "amd"]
        burstable_performance = "included"

        # max_spot_price_as_percentage_of_optimal_on_demand_price = 70   # 類似「最多接受 70% 價格」
        spot_max_price_percentage_over_lowest_price             = 100  # Spot 相對最低價可以到多少 %
        on_demand_max_price_percentage_over_lowest_price        = 120  # On-Demand 可接受的價差
      }

      # Network Configuration
      network_configuration {
        subnets         = module.vpc.private_subnets
        security_groups = [aws_security_group.ecs_instances.id]
      }
      
      # Storage Configuration
      storage_configuration {
        storage_size_gib = 50
      }

      # Monitoring
      monitoring = "BASIC"
    }

    # Tag Propagation
    propagate_tags = "CAPACITY_PROVIDER"
  }

  tags = {
    Name = "managed-instances-cp"
  }
}

resource "time_sleep" "wait_for_capacity_provider" {
  depends_on = [
    aws_ecs_capacity_provider.managed_instances
  ]
  create_duration  = "20s"
  destroy_duration = "15s"
}

# 將 Capacity Provider 關聯到 Cluster
resource "aws_ecs_cluster_capacity_providers" "main" {

  depends_on = [
    time_sleep.wait_for_capacity_provider
  ]
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = [aws_ecs_capacity_provider.managed_instances.name, "FARGATE_SPOT", "FARGATE"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = aws_ecs_capacity_provider.managed_instances.name
  }
}

# =============================================================================
# ECS Task Definition for Nginx
# =============================================================================

resource "aws_ecs_task_definition" "nginx" {
  family                   = "nginx-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2", "MANAGED_INSTANCES"] # 也可以加入 "MANAGED_INSTANCES" 當功能正式支援時
  cpu                      = "512"
  memory                   = "3072"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn = aws_iam_role.ecs_task_execution_role.arn

  # ARM64 架構 (for t4g instances)
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = "public.ecr.aws/nginx/nginx:stable"
      cpu       = 512
      memory    = 3072
      essential = true

      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
          name = "nginx"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/nginx-managed-instances"
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "nginx"
          "awslogs-create-group"  = "true"
        }
      }
    }
  ])

  tags = {
    Name = "nginx-task"
  }
}

resource "aws_ecs_service" "nginx" {
  name            = "nginx-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.nginx.arn
  desired_count   = local.desired_count

  # 使用 Capacity Provider Strategy
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed_instances.name
    weight            = 100
    base              = 1
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # 部署配置
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  # 等待服務穩定
  wait_for_steady_state = false

  enable_execute_command = true
  service_connect_configuration {
    enabled = true
    namespace = aws_service_discovery_http_namespace.service_discovery_namespace.arn
    

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group" = "/ecs/nginx-managed-instances"
        "awslogs-region" = data.aws_region.current.region
        "awslogs-stream-prefix" = "service-connect"
      }
    }
    service {
      port_name = "nginx"
      discovery_name = "nginx"
      client_alias {
        port = 80
        dns_name = "nginx.neil-lab.local"
      }
    }
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.ecs_infrastructure_role_policy,
    aws_iam_role_policy_attachment.ecs_instance_role_policy,
    aws_iam_instance_profile.ecs_instance_profile,
    aws_iam_role.ecs_task_execution_role,
    aws_iam_role_policy_attachment.ecs_task_execution_policy,
    aws_ecs_task_definition.nginx,
    module.vpc,
  ]

  tags = {
    Name = "nginx-service"
  }
}

resource "aws_ecs_service" "nginx_exec_ok" {
  name            = "nginx-service-exec-ok"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.nginx.arn
  desired_count   = local.desired_count
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed_instances.name
    weight            = 100
    base              = 1
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # 部署配置
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  # 等待服務穩定
  wait_for_steady_state = false

  enable_execute_command = true

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.ecs_infrastructure_role_policy,
    aws_iam_role_policy_attachment.ecs_instance_role_policy,
    aws_iam_instance_profile.ecs_instance_profile,
    aws_iam_role.ecs_task_execution_role,
    aws_iam_role_policy_attachment.ecs_task_execution_policy,
    aws_ecs_task_definition.nginx,
    module.vpc,
  ]

  tags = {
    Name = "nginx-service-exec-ok"
  }
}
resource "aws_ecs_service" "nginx_fargate" {
  name            = "nginx-service-fargate"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.nginx.arn
  desired_count   = local.desired_count

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
    base              = 1
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  wait_for_steady_state = false

  enable_execute_command = true

  service_connect_configuration {
    enabled = true
    namespace = aws_service_discovery_http_namespace.service_discovery_namespace.arn
    

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group" = "/ecs/nginx-managed-instances"
        "awslogs-region" = data.aws_region.current.region
        "awslogs-stream-prefix" = "service-connect"
      }
    }
    service {
      port_name = "nginx"
      discovery_name = "nginx-fargate"
      client_alias {
        port = 80
        dns_name = "nginx-fargate.neil-lab.local"
      }
    }
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.ecs_infrastructure_role_policy,
    aws_iam_role_policy_attachment.ecs_instance_role_policy,
    aws_iam_instance_profile.ecs_instance_profile,
    aws_iam_role.ecs_task_execution_role,
    aws_iam_role_policy_attachment.ecs_task_execution_policy,
    aws_ecs_task_definition.nginx,
    module.vpc,
  ]

  tags = {
    Name = "nginx-service-fargate"
  }
}

resource "aws_cloudwatch_log_group" "ecs_nginx" {
  name              = "/ecs/nginx-managed-instances"
  retention_in_days = 7

  tags = {
    Name = "ecs-nginx-logs"
  }
}
