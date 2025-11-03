terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.60" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.5" }
  }
}

provider "aws" { region = var.region }

# ---------------- VPC mínima (1 NATless, Lambda en subnets privadas con egress vía Internet GW) ----------------
resource "aws_vpc" "vpc" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "${var.project}-vpc" }
}
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags = { Name = "${var.project}-igw" }
}
resource "aws_subnet" "public" {
  count = 3
  vpc_id                  = aws_vpc.vpc.id
  availability_zone       = var.azs[count.index]
  cidr_block              = cidrsubnet(aws_vpc.vpc.cidr_block, 4, count.index)
  map_public_ip_on_launch = true
  tags = { Name = "${var.project}-public-${count.index}" }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id
  tags   = { Name = "${var.project}-public-rt" }
}
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}
resource "aws_route_table_association" "public_assoc" {
  count          = 3
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public[count.index].id
}

# Para simplificar: usaremos las "public" subnets para RDS/Lambda (no es lo más seguro en prod).
# En producción: subnets privadas + NAT o VPC endpoints.
locals {
  subnets = aws_subnet.public[*].id
}

# ---------------- Security Groups ----------------
resource "aws_security_group" "rds_sg" {
  name        = "${var.project}-rds-sg"
  description = "Allow MySQL from Lambda SG"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "MySQL 3306 from Lambda"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.lambda_sg.id]
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "lambda_sg" {
  name        = "${var.project}-lambda-sg"
  vpc_id      = aws_vpc.vpc.id
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------- RDS MySQL x3 ----------------
resource "random_password" "db_password" {
  length  = 16
  special = false
}

resource "aws_db_subnet_group" "db_subnets" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = local.subnets
}

resource "aws_db_instance" "db1" {
  identifier                = "${var.project}-db1"
  engine                    = "mysql"
  engine_version            = var.db_engine_version
  instance_class            = var.db_instance_class
  allocated_storage         = 20
  db_name                   = var.db_name
  username                  = var.db_user
  password                  = random_password.db_password.result
  db_subnet_group_name      = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids    = [aws_security_group.rds_sg.id]
  publicly_accessible       = true
  skip_final_snapshot       = true
  deletion_protection       = false
  apply_immediately         = true
}

resource "aws_db_instance" "db2" {
  identifier                = "${var.project}-db2"
  engine                    = "mysql"
  engine_version            = var.db_engine_version
  instance_class            = var.db_instance_class
  allocated_storage         = 20
  db_name                   = var.db_name
  username                  = var.db_user
  password                  = random_password.db_password.result
  db_subnet_group_name      = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids    = [aws_security_group.rds_sg.id]
  publicly_accessible       = true
  skip_final_snapshot       = true
  deletion_protection       = false
  apply_immediately         = true
}

resource "aws_db_instance" "db3" {
  identifier                = "${var.project}-db3"
  engine                    = "mysql"
  engine_version            = var.db_engine_version
  instance_class            = var.db_instance_class
  allocated_storage         = 20
  db_name                   = var.db_name
  username                  = var.db_user
  password                  = random_password.db_password.result
  db_subnet_group_name      = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids    = [aws_security_group.rds_sg.id]
  publicly_accessible       = true
  skip_final_snapshot       = true
  deletion_protection       = false
  apply_immediately         = true
}

# ---------------- IAM para Lambda ----------------
data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${var.project}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "xray_write" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ---------------- Construcción del paquete Lambda ----------------
# 1) pip install en carpeta local
resource "null_resource" "pip_install" {
  provisioner "local-exec" {
    command = <<EOT
      set -e
      rm -rf lambda_build && mkdir -p lambda_build
      cp -r ../lambda/* lambda_build/
      python -m pip install -r ../lambda/requirements.txt -t lambda_build
    EOT
    working_dir = path.module
  }
  triggers = {
    # vuelve a correr si cambian archivos
    always_run = timestamp()
  }
}

# 2) Crear ZIP
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_build"
  output_path = "${path.module}/lambda_build.zip"
  depends_on  = [null_resource.pip_install]
}

# ---------------- Lambda function + Alias + Provisioned Concurrency ----------------
resource "aws_lambda_function" "consistency" {
  function_name = "${var.project}-resolver"
  role          = aws_iam_role.lambda_role.arn
  handler       = "handler.handler"
  runtime       = "python3.11"
  filename      = data.archive_file.lambda_zip.output_path
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_mb
  tracing_config { mode = "Active" } # X-Ray
  environment {
    variables = {
      DB1_HOST = aws_db_instance.db1.address
      DB2_HOST = aws_db_instance.db2.address
      DB3_HOST = aws_db_instance.db3.address
      DB_USER  = var.db_user
      DB_PASS  = random_password.db_password.result
      DB_NAME  = var.db_name
      CONNECT_TIMEOUT = "0.05"
      READ_TIMEOUT    = "0.05"
      WRITE_TIMEOUT   = "0.05"
    }
  }
  vpc_config {
    security_group_ids = [aws_security_group.lambda_sg.id]
    subnet_ids         = local.subnets
  }
  depends_on = [aws_db_instance.db1, aws_db_instance.db2, aws_db_instance.db3]
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  description      = "Alias con PC"
  function_name    = aws_lambda_function.consistency.arn
  function_version = "$LATEST"
}

resource "aws_lambda_provisioned_concurrency_config" "pc" {
  function_name                     = aws_lambda_alias.live.function_name
  qualifier                         = aws_lambda_alias.live.name
  provisioned_concurrent_executions = var.lambda_provisioned
}

# ---------------- EventBridge: regla y target ----------------
resource "aws_cloudwatch_event_rule" "detect_inconsistency" {
  name        = "${var.project}-inconsistency-rule"
  description = "Dispara Lambda al detectar inconsistencia"
  event_pattern = jsonencode({
    "detail-type": ["InventoryInconsistencyDetected"]
  })
}
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.detect_inconsistency.name
  target_id = "ConsistencyResolver"
  arn       = aws_lambda_function.consistency.arn
}
resource "aws_lambda_permission" "allow_events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.consistency.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.detect_inconsistency.arn
}

# ---------------- CloudWatch Alarm (p95 ≤ 1000ms) ----------------
# Se usa Metric Math con EMF. Para simpleza aquí dejamos ejemplo de alarma a avg<1000ms; ajusta a p95 con Metrica de Insights si prefieres.
resource "aws_cloudwatch_metric_alarm" "latency_alarm" {
  alarm_name          = "${var.project}-resolutionLatencyMs>1000"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "resolutionLatencyMs"
  namespace           = "ConsistencyExperiment"
  period              = 60
  statistic           = "Average"
  threshold           = 1000
  alarm_description   = "Resolution latency over 1000ms"
}

