# AWS Terraform Assignment

This repository contains a single-file Terraform deployment for a production-style AWS architecture in the `ap-south-1` region (Mumbai). The infrastructure is implemented in one file: `main.tf`.

## Project Overview

The deployment creates the following resources:

- VPC with CIDR `10.0.0.0/16`
- 2 public subnets and 2 private subnets across 2 AZs
- Internet Gateway and NAT Gateway
- Public and private route tables with associations
- Bastion EC2 instance in a public subnet
- Application EC2 instance in a private subnet
- Security groups for bastion, app, and RDS
- Optional RDS MySQL instance
- S3 bucket with encryption, versioning, lifecycle rules, and blocked public access
- IAM role, instance profile, and policy for EC2 S3 access
- CloudWatch alarms and dashboard
- Optional Route 53 hosted zone and sample DNS record

This project intentionally keeps all Terraform logic in a single file and does not use modules.

## File Structure

```text
AWS_Terraform_Assignment/
├── main.tf
├── .gitignore
├── README.md
└── terraform.tfvars   (optional, local only for your values)
```

## Prerequisites

Before deploying, ensure the following are ready:

1. Terraform installed
   - Download from: https://developer.hashicorp.com/terraform/downloads
2. AWS CLI installed and configured
   - `aws configure` or environment variables
3. An existing EC2 key pair in `ap-south-1`
4. A valid administrator CIDR for SSH access to the bastion
5. A suitable S3 backend bucket and DynamoDB lock table if you want to use remote state

## AWS Authentication

Set AWS credentials before running Terraform:

```bash
aws configure
```

or export them:

```bash
export AWS_ACCESS_KEY_ID="your_access_key"
export AWS_SECRET_ACCESS_KEY="your_secret_key"
export AWS_DEFAULT_REGION="ap-south-1"
```

## Important Configuration Before Deploying

Open `main.tf` and review these variables:

- `key_pair_name`
- `admin_cidr`
- `db_password`
- `enable_rds`
- `enable_route53`
- `route53_domain`

### Recommended initial settings

```hcl
variable "key_pair_name" {
  default = "YOUR_EC2_KEY_PAIR_NAME"
}

variable "admin_cidr" {
  default = "YOUR_PUBLIC_IP/32"
}

variable "enable_rds" {
  default = false
}

variable "enable_route53" {
  default = false
}
```

Important:

- `admin_cidr` should not be `0.0.0.0/0` unless you intentionally want public SSH exposure.
- `enable_rds` is defaulted to `false` for lab safety and cost control.
- Set `db_password` securely before enabling RDS.

## Variables and Secrets

Set sensitive values in a local file such as `terraform.tfvars`:

```hcl
key_pair_name = "my-keypair"
admin_cidr    = "203.0.113.10/32"
db_password   = "StrongPassword!123"
```

If you do not want to store values in a file, pass them at runtime:

```bash
terraform apply -var="key_pair_name=my-keypair" \
  -var="admin_cidr=203.0.113.10/32" \
  -var="db_password=StrongPassword!123"
```

## Optional Remote State Setup

The configuration includes a commented S3 backend example. Before enabling it, create an S3 bucket and DynamoDB table manually.

Example:

```hcl
terraform {
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "terraform/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "your-lock-table"
    encrypt        = true
  }
}
```

Then run:

```bash
terraform init
```

## Deployment Steps

### 1) Initialize Terraform

```bash
terraform init
```

### 2) Review the plan

```bash
terraform plan
```

### 3) Apply the infrastructure

```bash
terraform apply
```

If you want to pass custom values:

```bash
terraform apply -var-file="terraform.tfvars"
```

### 4) Confirm outputs

After apply, Terraform prints useful outputs such as:

- Bastion public IP
- VPC ID
- Private/public subnet IDs
- S3 bucket name
- RDS endpoint (if enabled)

### 5) Connect to the bastion

```bash
ssh -i your-key.pem ec2-user@<BastionPublicIP>
```

### 6) Connect to the app server from the bastion (if SSH is permitted)

```bash
ssh -i your-key.pem ec2-user@<ApplicationPrivateIP>
```

## Optional Features

### Enable RDS

Update the variable:

```hcl
variable "enable_rds" {
  default = true
}
```

Then apply:

```bash
terraform apply -var="enable_rds=true" -var="db_password=YourStrongPassword!"
```

### Enable Route 53

Update:

```hcl
enable_route53 = true
route53_domain = "example.com"
```

Then apply:

```bash
terraform apply -var="enable_route53=true" -var="route53_domain=example.com"
```

## Destroy Infrastructure

When testing is complete, tear down the stack:

```bash
terraform destroy
```

To avoid accidental cost accumulation, destroy resources after validation or when not needed.

## Notes

- This project is intentionally implemented in one file: `main.tf`.
- NAT Gateway and RDS add cost; keep them disabled when not needed.
- The architecture uses least-privilege security groups and restricted access.
- For cost-sensitive labs, leave `enable_rds = false` until required.
- Do not commit AWS credentials or `.pem` files to GitHub.

## Recommended .gitignore Entries

```gitignore
.terraform/
.terraform.lock.hcl
terraform.tfstate
terraform.tfstate.backup
*.pem
*.tfvars
crash.log
```

## Useful Commands

```bash
terraform fmt
terraform validate
terraform plan
terraform apply
terraform destroy
```

## Submission Checklist

For assignment submission, prepare the following:

- Terraform code in `main.tf`
- README.md with setup and deployment steps
- Screenshots of the deployed resources in AWS Console
- Architecture diagram of the network and services
- Cost estimate for running the environment
- State backend configuration notes
- GitHub repository link if required

## License

This project is intended for learning and assignment use.
