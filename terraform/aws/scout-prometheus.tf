locals {
  prometheus_docker_image = var.prometheus_docker_image == null ? aws_ecr_repository.prometheus[0].repository_url : var.prometheus_docker_image
  scout_docker_image      = var.scout_docker_image == null ? aws_ecr_repository.scout[0].repository_url : var.scout_docker_image
}

resource "aws_ecs_service" "prometheus" {
  name            = "${var.app_name}-prometheus"
  task_definition = aws_ecs_task_definition.prometheus.id
  cluster         = aws_ecs_cluster.scout.name
  desired_count   = 1
  load_balancer {
    container_name   = "prometheus"
    container_port   = 9090
    target_group_arn = aws_lb_target_group.prometheus.arn
  }
  depends_on = [aws_lb_listener.prometheus]
}

resource "aws_ecs_task_definition" "prometheus" {
  container_definitions = jsonencode(concat(
    jsondecode(module.prometheus-container-definition.json_map_encoded_list),
  jsondecode(module.scout-container-definition.json_map_encoded_list),
  jsondecode(module.bsc-scout-container-definition.json_map_encoded_list),
  jsondecode(module.scout-bridge-definition.json_map_encoded_list),
  jsondecode(module.scout-ibbtc-definition.json_map_encoded_list)))
  family                   = "${var.app_name}-prometheus"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_exec.arn
  network_mode             = "bridge"
  volume {
    name      = "prometheus-data"
    host_path = "${local.mount_point}/prometheus-data"
  }
}

module "prometheus-container-definition" {
  source                       = "cloudposse/ecs-container-definition/aws"
  version                      = "0.47.0"
  container_image              = local.prometheus_docker_image ##TODO add versioning
  container_name               = "prometheus"
  container_memory_reservation = 250
  essential                    = true
  links = ["scout-collector", "bsc-collector", "events"]
  mount_points = [
    {
      containerPath = "/prometheus"
      sourceVolume  = "prometheus-data"
    }
  ]
  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.scout.id
      awslogs-region        = var.region
      awslogs-stream-prefix = "prometheus"
    }
  }
  port_mappings = [
    {
      ## Main port
      containerPort = 9090
      hostPort = null
      protocol      = "tcp"
    }
  ]
}
module "bsc-scout-container-definition" {
  source                       = "cloudposse/ecs-container-definition/aws"
  version                      = "0.47.0"
  container_image              = local.scout_docker_image ## TODO make optional
  container_name               = "bsc-collector"
  essential                    = false ## TODO change to true when stable
  container_memory_reservation = 250
  entrypoint = ["./startBsc.sh"]
  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.scout.id
      awslogs-region        = var.region
      awslogs-stream-prefix = "bsc-scout"
    }
  }

  secrets = [
    {
      name      = "ETHNODEURL"
      valueFrom = var.bsc_url_ssm_parameter_name
    }]
}
module "scout-bridge-definition" {
  source                       = "cloudposse/ecs-container-definition/aws"
  version                      = "0.47.0"
  container_image              = local.scout_docker_image ## TODO make optional
  container_name               = "events"
  essential                    = false ## TODO change to true when stable
  container_memory_reservation = 250
  entrypoint = ["./startBridge.sh"]
  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.scout.id
      awslogs-region        = var.region
      awslogs-stream-prefix = "scout-events"
    }
  }

  secrets = [
    {
      name      = "ETHNODEURL"
      valueFrom = var.ethnode_url_ssm_parameter_name
    }]
}
module "scout-ibbtc-definition" {
  source                       = "cloudposse/ecs-container-definition/aws"
  version                      = "0.47.0"
  container_image              = local.scout_docker_image ## TODO make optional
  container_name               = "ibbtc"
  essential                    = false ## TODO change to true when stable
  container_memory_reservation = 250
  entrypoint = ["./startIbbtc.sh"]
  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.scout.id
      awslogs-region        = var.region
      awslogs-stream-prefix = "scout-events"
    }
  }
  secrets = [
    {
      name      = "ETHNODEURL"
      valueFrom = var.ethnode_url_ssm_parameter_name
    }]
}
module "scout-container-definition" {
  source                       = "cloudposse/ecs-container-definition/aws"
  version                      = "0.47.0"
  container_image              = local.scout_docker_image
  container_name               = "scout-collector"
  essential                    = true
  container_memory_reservation = 250
  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.scout.id
      awslogs-region        = var.region
      awslogs-stream-prefix = "scout"
    }
  }

  secrets = [
    {
      name      = "ETHNODEURL"
      valueFrom = var.ethnode_url_ssm_parameter_name
  }]
}
resource "aws_lb_target_group" "prometheus" {
  name        = "${var.app_name}-prometheus"
  protocol    = "HTTP"
  port        = 9090
  target_type = "instance"
  vpc_id      = local.vpc_id
  tags = {
    name = "prometheus"
  }
  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 6
    timeout             = 5
    interval            = 10
    path                = "/-/healthy"
  }
}

## If so they need their own target groups.
resource "aws_lb_listener" "prometheus" {
  load_balancer_arn = data.aws_lb.private_alb.arn
  port              = var.prometheus_lb_port
  protocol          = "HTTPS"
  certificate_arn = var.root_domain_wildcard_acm_cert_arn
  default_action {
    target_group_arn = aws_lb_target_group.prometheus.arn
    type             = "forward"
  }
}
resource "aws_route53_record" "prometheus" {
  name    = "${var.app_name}-prometheus"
  type    = "A"
  zone_id = data.aws_route53_zone.rootzone.zone_id
  alias {
    evaluate_target_health = false
    name                   = data.aws_lb.private_alb.dns_name
    zone_id                = data.aws_lb.private_alb.zone_id
  }
}
