###############################################################################
# main.tf - Single-file Terraform implementation for AWS Mumbai (ap-south-1)
#
# - Everything (providers, variables, resources, outputs) is in this file.
# - No modules, no separate .tf files.
# - Heavily commented for education and safe operation.
#
# IMPORTANT: Edit the backend block (commented below) to point to an existing
# S3 bucket and DynamoDB table BEFORE running `terraform init`.
#
# WARNING: This deployment creates chargeable resources:
# - NAT Gateway (hourly + data processing)
# - EC2 instances
# - RDS instance (Multi-AZ)
# - EIP
# Destroy resources after testing to avoid costs.
###############################################################################

# ------------------------------
# OPTIONAL: S3 Backend (REPLACE PLACEHOLDERS BEFORE INIT)
# ------------------------------
# The backend configuration cannot use variables. Create the S3 bucket and
# DynamoDB table for state locking manually BEFORE running `terraform init`.
#
# Replace REPLACE_WITH_YOUR_STATE_BUCKET and REPLACE_WITH_YOUR_DYNAMODB_TABLE
# with the actual resource names.
#
# Example (UNCOMMENT and edit before terraform init):
#
 terraform {
   backend "s3" {
     bucket = "shravanis31"
     key = "terraform/terraform.tfstate"
     region = "ap-south-1"
     dynamodb_table = "sss"
     encrypt = true
    }
   required_version = ">= 1.3"
 }

# NOTE: Leave this commented until you have created the S3 bucket and DynamoDB.
###############################################################################

terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }

  # Leave backend block commented (see instructions above).
}

# ------------------------------
# Providers
# ------------------------------
provider "aws" {
  region = "ap-south-1"
  # Optionally use assume_role, profile, or other auth methods via environment or CLI
}

provider "random" {}

# ------------------------------
# Data: pick the first two available AZs in the region dynamically
# ------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

# Get a recent Amazon Linux 2 AMI in ap-south-1 (ARM/ x86 selection via filter)
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"] # Amazon Linux 2, x86_64
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ------------------------------
# VARIABLES - All defined here (single file requirement)
# ------------------------------
variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name prefix for resources"
  type        = string
  default     = "terraform-aws-assignment"
}

variable "key_pair_name" {
  description = "Existing EC2 Key Pair name to use for Bastion (must exist in the region)"
  type        = string
  default     = "sss" # Change before apply
}

variable "admin_cidr" {
  description = "CIDR that can reach Bastion SSH (set to your admin IP or office range). Do NOT leave as 0.0.0.0/0 in production."
  type        = string
  default     = "59.152.121.239/32" # Strongly recommended: update to your IP e.g., 203.0.113.5/32
}

variable "instance_type" {
  description = "EC2 instance type for bastion and app (default uses t3.micro for cost-safety)."
  type        = string
  default     = "t3.micro"
}

variable "app_port" {
  description = "Application port (example: 80 for HTTP)."
  type        = number
  default     = 80
}

variable "public_subnet_cidrs" {
  description = "List of public subnet CIDRs (2 entries for 2 AZs)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of private subnet CIDRs (2 entries for 2 AZs)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "db_name" {
  description = "RDS initial database name"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "RDS master password (sensitive - no default)"
  type        = string
  sensitive   = true
  default     = null
}

variable "db_instance_class" {
  description = "RDS instance class (size). Use small class for lab."
  type        = string
  default     = "db.t3.micro"
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS (recommended true for HA; incurs cost)."
  type        = bool
  default     = true
}

variable "db_allocated_storage" {
  description = "Allocated storage (GB) for RDS"
  type        = number
  default     = 20
}

variable "db_backup_retention" {
  description = "Number of days to retain DB backups"
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Whether to enable deletion protection on the DB (default false for easy cleanup)"
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip final snapshot on DB delete (true to skip). Set to false to keep a final snapshot."
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "Enable RDS resources. Set to false to skip creating RDS for testing or cost savings."
  type        = bool
  default     = false
}

variable "enable_route53" {
  description = "Enable Route53 resources (hosted zone and sample record)"
  type        = bool
  default     = false
}

variable "route53_domain" {
  description = "Domain for Route53 hosted zone (example: example.com). Only used if enable_route53 = true"
  type        = string
  default     = ""
}

variable "route53_record_name" {
  description = "Subdomain (left part) to create as sample record when route53 enabled (example: app)"
  type        = string
  default     = "app"
}

variable "cpu_alarm_threshold" {
  description = "CPU utilization threshold (percent) for CloudWatch alarms"
  type        = number
  default     = 70
}

# ------------------------------
# LOCALS - naming, AZ selection, and workspace-aware sizing
# ------------------------------
locals {
  env                    = terraform.workspace == "default" ? "dev" : terraform.workspace
  name_prefix            = "${var.project_name}-${local.env}"
  azs                   = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnet_count    = length(var.public_subnet_cidrs)
  private_subnet_count   = length(var.private_subnet_cidrs)

  # Validate lists are consistent with AZ count (helpful during plan/validate)
  subnet_validation = (
    local.public_subnet_count == 2 && local.private_subnet_count == 2
  )

  # Resource naming helpers
  vpc_name               = "${local.name_prefix}-vpc"
  igw_name               = "${local.name_prefix}-igw"
  nat_name               = "${local.name_prefix}-nat"
  bastion_name           = "${local.name_prefix}-bastion"
  app_name               = "${local.name_prefix}-app"
  rds_identifier         = "${local.name_prefix}-rds"
  s3_bucket_name         = "${replace("${local.name_prefix}-${random_id.bucket_suffix.hex}", "_", "-") }"
  s3_bucket_arn          = "arn:aws:s3:::${local.s3_bucket_name}"
  # Determine smaller instance classes for dev vs prod optionally (example of workspace usage)
  chosen_instance_type   = terraform.workspace == "prod" ? var.instance_type : var.instance_type
  chosen_db_class        = terraform.workspace == "prod" ? var.db_instance_class : var.db_instance_class

  # Dashboard JSON will be built with jsonencode below using resource ids
}

# Safety check (will not stop terraform; human must ensure var lists match expected)
# If local.subnet_validation is false, the plan may produce unexpected results. Check inputs.
###############################################################################
# NETWORKING: VPC, Subnets, IGW, NAT, Route Tables
###############################################################################

# VPC
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = local.vpc_name
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name        = local.igw_name
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# PUBLIC SUBNETS: create using for_each over index -> ensures AZ selection is dynamic
resource "aws_subnet" "public" {
  for_each = {
    for idx, cidr in var.public_subnet_cidrs :
    idx => {
      cidr = cidr
      az   = local.azs[idx]
      name = "${local.name_prefix}-public-${idx + 1}"
    }
  }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name        = each.value.name
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# PRIVATE SUBNETS: create using for_each similarly
resource "aws_subnet" "private" {
  for_each = {
    for idx, cidr in var.private_subnet_cidrs :
    idx => {
      cidr = cidr
      az   = local.azs[idx]
      name = "${local.name_prefix}-private-${idx + 1}"
    }
  }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name        = each.value.name
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# Elastic IP for NAT Gateway (count = 1 NAT)
resource "aws_eip" "nat_eip" {
  count = 1

  tags = {
    Name        = "${local.nat_name}-eip"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# NAT Gateway: place in the first public subnet (cost: hourly)
resource "aws_nat_gateway" "nat" {
  count = 1
  allocation_id = aws_eip.nat_eip[0].id
  subnet_id     = element(values(aws_subnet.public), 0).id
  # The previous line fetches the first public subnet ID in an order-insensitive way.

  tags = {
    Name        = local.nat_name
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }

  depends_on = [aws_internet_gateway.igw]
}

# PUBLIC ROUTE TABLE
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "${local.name_prefix}-rt-public"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# Associate public route table to all public subnets
resource "aws_route_table_association" "public_assoc" {
  for_each = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# PRIVATE ROUTE TABLES (one per private subnet - demonstrates for_each)
resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[0].id
  }

  tags = {
    Name        = "${local.name_prefix}-rt-private-${each.key + 1}"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }

  depends_on = [aws_nat_gateway.nat]
}

# Associate each private route table with its private subnet
resource "aws_route_table_association" "private_assoc" {
  for_each = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

###############################################################################
# SECURITY GROUPS - Bastion, Application, RDS (least privilege)
###############################################################################

# Bastion SG: SSH from admin_cidr only
resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-sg-bastion"
  description = "Bastion SG - allow SSH from admin CIDR"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = [var.admin_cidr]
    content {
      description = "SSH from admin CIDR"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "${local.name_prefix}-sg-bastion"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# Application SG
resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-sg-app"
  description = "Application SG - allow SSH from bastion and app port from admin CIDR/VPC"
  vpc_id      = aws_vpc.this.id

  # Allow SSH from bastion SG (use security_groups reference)
  ingress {
    description       = "SSH from bastion SG"
    from_port         = 22
    to_port           = 22
    protocol          = "tcp"
    security_groups   = [aws_security_group.bastion.id]
  }

  # Allow application port from admin CIDR and VPC CIDR (least-privilege example)
  dynamic "ingress" {
    for_each = [var.admin_cidr, var.vpc_cidr]
    content {
      description = ingress.value == var.admin_cidr ? "App port from admin CIDR" : "App port from VPC"
      from_port   = var.app_port
      to_port     = var.app_port
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name        = "${local.name_prefix}-sg-app"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# RDS SG: allow MySQL 3306 ONLY from application SG
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-sg-rds"
  description = "RDS SG - MySQL only from app SG"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "MySQL from app SG"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # DB needs outbound to allow replication/updates etc.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name_prefix}-sg-rds"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

###############################################################################
# COMPUTE: EC2 Bastion (public) and Application (private)
###############################################################################

# IAM Role and Instance Profile for the Application EC2 to access S3
resource "aws_iam_role" "app_ec2_role" {
  name = "${local.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "${local.name_prefix}-ec2-role"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# IAM policy allowing least-privilege S3 access to the bucket
resource "aws_iam_policy" "app_s3_policy" {
  name        = "${local.name_prefix}-s3-policy"
  description = "Allow app EC2 to access application S3 bucket"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "AllowListAndRead"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${local.s3_bucket_arn}",
          "${local.s3_bucket_arn}/*"
        ]
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "app_attach" {
  role       = aws_iam_role.app_ec2_role.name
  policy_arn = aws_iam_policy.app_s3_policy.arn
}

# Instance profile
resource "aws_iam_instance_profile" "app_instance_profile" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.app_ec2_role.name
}

# Random suffix for S3 bucket to ensure uniqueness (demonstrates random provider)
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# S3 Bucket for application storage (versioning, SSE, block public access, lifecycle)
resource "aws_s3_bucket" "app_bucket" {
  bucket = local.s3_bucket_name

  # Server-side encryption by default (SSE-S3)
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  versioning {
    enabled = true
  }

  tags = {
    Name        = "${local.name_prefix}-bucket"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

# S3 public access block (manage blocking public access separately)
resource "aws_s3_bucket_public_access_block" "block" {
  bucket = aws_s3_bucket.app_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Lifecycle rules: transit to STANDARD_IA, expire objects, manage noncurrent versions, abort incomplete multipart uploads
resource "aws_s3_bucket_lifecycle_configuration" "lifecycle" {
  bucket = aws_s3_bucket.app_bucket.id

  rule {
    id     = "default-rule"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# EC2 Bastion (public subnet, public IP, SSH)
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.instance_type
  availability_zone           = local.azs[0]
  subnet_id                   = element(values(aws_subnet.public), 0).id
  key_name                    = var.key_pair_name
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.bastion.id]

  tags = {
    Name        = local.bastion_name
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }

  # Basic user data to install lightweight agent (no secrets)
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              # Install small monitoring agent placeholder or tools (no secrets)
              EOF
}

# EC2 Application server (private subnet, no public IP, IAM instance profile)
resource "aws_instance" "app" {
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.instance_type
  availability_zone           = local.azs[0]
  subnet_id                   = element(values(aws_subnet.private), 0).id
  key_name                    = var.key_pair_name
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app_instance_profile.name

  tags = {
    Name        = local.app_name
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }

  # User data example: install a minimal app and demonstrate S3 usage (no keys)
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl enable httpd
              systemctl start httpd
              echo "Hello from ${local.app_name} - $(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)" > /var/www/html/index.html
              EOF

  # Ensure creation happens after networking and IAM are in place
  depends_on = [aws_iam_instance_profile.app_instance_profile, aws_subnet.private]
}

###############################################################################
# RDS: Subnet group and MySQL instance (Multi-AZ, encrypted, private)
###############################################################################

resource "aws_db_subnet_group" "rds_subnets" {
  count      = var.enable_rds ? 1 : 0
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = [for s in aws_subnet.private : s.id]

  tags = {
    Name        = "${local.name_prefix}-db-subnet-group"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

resource "aws_db_instance" "mysql" {
  count                   = var.enable_rds ? 1 : 0
  identifier              = local.rds_identifier
  engine                  = "mysql"
  engine_version          = "8.0" # Current supported major version (confirm in region)
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  db_subnet_group_name    = var.enable_rds ? aws_db_subnet_group.rds_subnets[0].name : null
  vpc_security_group_ids  = [aws_security_group.rds.id]
  multi_az                = var.db_multi_az
  storage_encrypted       = true
  backup_retention_period = var.db_backup_retention
  deletion_protection     = var.db_deletion_protection
  skip_final_snapshot     = var.db_skip_final_snapshot
  publicly_accessible     = false

  tags = {
    Name        = local.rds_identifier
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }

  # Minimal storage and performance options for lab
  depends_on = [aws_db_subnet_group.rds_subnets]
}

###############################################################################
# CLOUDWATCH: Alarms and Dashboard
###############################################################################

# Metric alarms for Bastion and App EC2 CPU
resource "aws_cloudwatch_metric_alarm" "bastion_cpu_alarm" {
  alarm_name          = "${local.name_prefix}-bastion-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold

  dimensions = {
    InstanceId = aws_instance.bastion.id
  }

  alarm_description = "Alarm if bastion CPU exceeds ${var.cpu_alarm_threshold}%"
  alarm_actions     = []
  ok_actions        = []
}

resource "aws_cloudwatch_metric_alarm" "app_cpu_alarm" {
  alarm_name          = "${local.name_prefix}-app-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold

  dimensions = {
    InstanceId = aws_instance.app.id
  }

  alarm_description = "Alarm if app CPU exceeds ${var.cpu_alarm_threshold}%"
  alarm_actions     = []
  ok_actions        = []
}

# CloudWatch Dashboard - JSON constructed with jsonencode
locals {
  app_widget = {
    type = "metric"
    x    = 0
    y    = 0
    width = 12
    height = 6
    properties = {
      metrics = [ [ "AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id ] ]
      view = "timeSeries"
      region = var.aws_region
      title = "Application EC2 CPU"
    }
  }

  bastion_widget = {
    type = "metric"
    x    = 12
    y    = 0
    width = 12
    height = 6
    properties = {
      metrics = [ [ "AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.bastion.id ] ]
      view = "timeSeries"
      region = var.aws_region
      title = "Bastion EC2 CPU"
    }
  }

  rds_widget = var.enable_rds ? [
    {
      type = "metric"
      x = 0
      y = 6
      width = 12
      height = 6
      properties = {
        metrics = [
          [ "AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.mysql[0].id ],
          [ ".", "DatabaseConnections", ".", ".", { stat = "Average" } ]
        ]
        view = "timeSeries"
        region = var.aws_region
        title = "RDS - CPU & Connections"
      }
    }
  ] : []

  dashboard = jsonencode({ widgets = concat([local.app_widget, local.bastion_widget], local.rds_widget) })
}

resource "aws_cloudwatch_dashboard" "dashboard" {
  dashboard_name = "${local.name_prefix}-dashboard"
  dashboard_body = local.dashboard
}

###############################################################################
# ROUTE53 (optional) - create hosted zone and A record pointing to Bastion public IP
###############################################################################

resource "aws_route53_zone" "zone" {
  count = var.enable_route53 ? 1 : 0
  name  = var.route53_domain

  tags = {
    Name        = "${local.name_prefix}-hosted-zone"
    Project     = "AWS-Terraform-Assignment"
    Environment = local.env
    ManagedBy   = "Terraform"
  }
}

resource "aws_route53_record" "sample" {
  count = var.enable_route53 ? 1 : 0
  zone_id = aws_route53_zone.zone[0].zone_id
  name    = "${var.route53_record_name}.${var.route53_domain}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.bastion.public_ip]
}

###############################################################################
# OUTPUTS
###############################################################################

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = [for s in aws_subnet.private : s.id]
}

output "bastion_public_ip" {
  description = "Bastion public IP"
  value       = aws_instance.bastion.public_ip
}

output "bastion_public_dns" {
  description = "Bastion public DNS name"
  value       = aws_instance.bastion.public_dns
}

output "app_private_ip" {
  description = "Application EC2 private IP"
  value       = aws_instance.app.private_ip
}

output "rds_endpoint" {
  description = "RDS endpoint address (empty if RDS disabled)"
  value       = var.enable_rds ? aws_db_instance.mysql[0].endpoint : ""
}

output "s3_bucket_name" {
  description = "Application S3 bucket name"
  value       = aws_s3_bucket.app_bucket.bucket
}

output "route53_zone_id" {
  description = "Route53 hosted zone ID (if enabled)"
  value       = try(aws_route53_zone.zone[0].zone_id, "")
  sensitive   = false
}

###############################################################################
# VALIDATION & NOTES
#
# - Confirm var.public_subnet_cidrs and var.private_subnet_cidrs each contain exactly 2 entries.
# - Edit variables such as key_pair_name, admin_cidr, and route53_domain as required.
# - Provide db_password at plan/apply time securely (see instructions below).
###############################################################################
