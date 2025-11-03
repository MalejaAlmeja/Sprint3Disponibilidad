terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws     = { source = "hashicorp/aws",    version = "~> 5.60" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.5" }
  }
}

provider "aws" {
  region = var.region
}

# ======================= VPC por defecto (NO se crea VPC nueva) =======================
data "aws_default_vpc" "default" {}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_default_vpc.default.id]
  }
}

# Toma 3 subnets de la VPC por defecto
locals {
  subnets = slice(data.aws_subnets.default.ids, 0, 3)
}

# ======================= Security Groups en la VPC por defecto =======================
resource "aws_security_group" "rds_sg" {
  name        = "${var.project}-rds-sg"
  description = "Allow MySQL from Internet (LAB ONLY)"
  vpc_id      = data.aws_default_vpc.default.id

  ingress {
    description = "MySQL 3306 from anywhere (LAB ONLY)"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-rds-sg" }
}

# (Opcional) SG para Lambda, por si luego activas VPC access
resource "aws_security_group" "lambda_sg" {
  name   = "${var.project}-lambda-sg"
  vpc_id = data.aws_default_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-lambda-sg" }
}

# ======================= Subnet Group con sufijo aleatorio =======================
resource "random_id" "sg_suffix" {
  byte_length = 2
}

resource "aws_db_subnet_group" "db_subnets" {
  name       = "${var.project}-db-subnet-group-${random_id.sg_suffix.hex}"
  subnet_ids = local.subnets

  tags = {
    Name = "${var.project}-db-subnet-group-${random_id.sg_suffix.hex}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ======================= Secrets / Password =======================
resource "random_password" "db_password" {
  length  = 16
  special = false
}

# ======================= RDS x3 (MySQL, gp3, sin engine_version) =======================
resource "aws_db_instance" "db1" {
  identifier             = "${var.project}-db1"
  engine                 = "mysql"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = var.db_name
  username               = var.db_user
  password               = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = true
  skip_final_snapshot    = true
  deletion_protection    = false
  apply_immediately      = true
  tags = { Name = "${var.project}-db1" }
}

resource "aws_db_instance" "db2" {
  identifier             = "${var.project}-db2"
  engine                 = "mysql"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = var.db_name
  username               = var.db_user
  password               = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = true
  skip_final_snapshot    = true
  deletion_protection    = false
  apply_immediately      = true
  tags = { Name = "${var.project}-db2" }
}

resource "aws_db_instance" "db3" {
  identifier             = "${var.project}-db3"
  engine                 = "mysql"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = var.db_name
  username               = var.db_user
  password               = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible    = true
  skip_final_snapshot    = true
  deletion_protection    = false
  apply_immediately      = true
  tags = { Name = "${var.project}-db3" }
}

# ======================= Empaquetado Lambda (zip local) =======================
resource "null_resource" "pip_install" {
  provisioner "local-exec" {
    working_dir = path.module
    command     = <<EOT
set -e
rm -rf lambda_build
mkdir -p lambda_build
cp -r ../lambda/* lambda_build/
python -m pip install --no-cache-dir -r ../lambda/requirements.txt -t lambda_build
EOT
  }
  triggers = { always = timestamp() }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_build"
  output_path = "${path.module}/lambda_build.zip"
  depends_on  = [null_resource.pip_install]
}

# ======================= Lambda (opcional, SIN VPC; controlado por enable_lambda) =======================
resource "aws_lambda_function" "consistency" {
  count         = var.enable_lambda ? 1 : 0

  function_name = "${var.project}-resolver"
  role          = var.existing_lambda_role_arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  filename      = data.archive_file.lambda_zip.output_path
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout
  publish       = true

  tracing_config { mode = "Active" } # X-Ray si el rol lo permite

  # SIN VPC para no requerir AWSLambdaVPCAccessExecutionRole
  environment {
    variables = {
      DB1_HOST        = aws_db_instance.db1.address
      DB2_HOST        = aws_db_instance.db2.address
      DB3_HOST        = aws_db_instance.db3.address
      DB_USER         = var.db_user
      DB_PASS         = random_password.db_password.result
      DB_NAME         = var.db_name
      CONNECT_TIMEOUT = "0.05"
      READ_TIMEOUT    = "0.05"
      WRITE_TIMEOUT   = "0.05"
    }
  }

  depends_on = [
    aws_db_instance.db1,
    aws_db_instance.db2,
    aws_db_instance.db3
  ]
}

resource "aws_lambda_alias" "live" {
  count            = var.enable_lambda ? 1 : 0
  name             = "live"
  description      = "Alias con provisioned concurrency"
  function_name    = aws_lambda_function.consistency[0].function_name
  function_version = aws_lambda_function.consistency[0].version
}

resource "aws_lambda_provisioned_concurrency_config" "pc" {
  count                              = var.enable_lambda ? 1 : 0
  function_name                      = aws_lambda_function.consistency[0].function_name
  qualifier                          = aws_lambda_alias.live[0].name
  provisioned_concurrent_executions  = var.lambda_provisioned
}

# ======================= EventBridge (opcional; controlado por enable_lambda) =======================
resource "aws_cloudwatch_event_rule" "detect_inconsistency" {
  count       = var.enable_lambda ? 1 : 0
  name        = "${var.project}-inconsistency-rule"
  description = "Dispara Lambda al detectar inconsistencia"
  event_pattern = jsonencode({
    "detail-type" : ["InventoryInconsistencyDetected"]
  })
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  count     = var.enable_lambda ? 1 : 0
  rule      = aws_cloudwatch_event_rule.detect_inconsistency[0].name
  target_id = "ConsistencyResolver"
  arn       = aws_lambda_function.consistency[0].arn
}

resource "aws_lambda_permission" "allow_events" {
  count         = var.enable_lambda ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.consistency[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.detect_inconsistency[0].arn
}

# ======================= CloudWatch Alarm (métrica custom) =======================
resource "aws_cloudwatch_metric_alarm" "latency_alarm" {
  alarm_name          = "${var.project}-resolutionLatencyMs>1000"
  alarm_description   = "Resolution latency over 1000ms (avg)"
  namespace           = "ConsistencyExperiment"
  metric_name         = "resolutionLatencyMs"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1000
  comparison_operator = "GreaterThanThreshold"
}
