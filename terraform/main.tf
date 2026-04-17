terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region"       { default = "us-east-1" }
variable "github_owner"     { description = "GitHub username/org" }
variable "github_repo"      { description = "GitHub repo name" }
variable "github_branch"    { default = "main" }
variable "github_oauth_token" {
  description = "GitHub personal access token (store in SSM or env)"
  sensitive   = true
}
variable "eks_cluster_name" { default = "demo-cluster" }

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# ── ECR Repository ──────────────────────────────────────────────────────────
resource "aws_ecr_repository" "app" {
  name                 = "eks-demo-app"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

# ── S3 bucket for pipeline artifacts ────────────────────────────────────────
resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket        = "eks-demo-pipeline-artifacts-${local.account_id}"
  force_destroy = true
}

# ── CodeBuild IAM Role ───────────────────────────────────────────────────────
resource "aws_iam_role" "codebuild" {
  name = "eks-demo-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${local.region}:${local.account_id}:cluster/${var.eks_cluster_name}"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.pipeline_artifacts.arn}/*"
      }
    ]
  })
}

# ── CodeBuild Project ────────────────────────────────────────────────────────
resource "aws_codebuild_project" "app" {
  name          = "eks-demo-build"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true   # required for Docker-in-Docker
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = local.account_id
    }
    environment_variable {
      name  = "EKS_CLUSTER_NAME"
      value = var.eks_cluster_name
    }
  }

  artifacts { type = "CODEPIPELINE" }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/eks-demo"
      stream_name = "build"
    }
  }
}

# ── CodePipeline IAM Role ────────────────────────────────────────────────────
resource "aws_iam_role" "codepipeline" {
  name = "eks-demo-pipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  role = aws_iam_role.codepipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = [aws_s3_bucket.pipeline_artifacts.arn, "${aws_s3_bucket.pipeline_artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = aws_codebuild_project.app.arn
      }
    ]
  })
}

# ── CodePipeline ─────────────────────────────────────────────────────────────
resource "aws_codepipeline" "app" {
  name     = "eks-demo-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.pipeline_artifacts.bucket
  }

  stage {
    name = "Source"
    action {
      name             = "GitHub_Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        Owner                = var.github_owner
        Repo                 = var.github_repo
        Branch               = var.github_branch
        OAuthToken           = var.github_oauth_token
        PollForSourceChanges = "false"   # use webhook instead
      }
    }
  }

  stage {
    name = "Build_and_Deploy"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      configuration = {
        ProjectName = aws_codebuild_project.app.name
      }
    }
  }
}

# ── GitHub Webhook (push → pipeline trigger) ─────────────────────────────────
resource "aws_codepipeline_webhook" "github" {
  name            = "eks-demo-webhook"
  target_action   = "GitHub_Source"
  target_pipeline = aws_codepipeline.app.name
  authentication  = "GITHUB_HMAC"

  authentication_configuration {
    secret_token = random_password.webhook_secret.result
  }

  filter {
    json_path    = "$.ref"
    match_equals = "refs/heads/${var.github_branch}"
  }
}

resource "random_password" "webhook_secret" {
  length  = 32
  special = false
}

# ── Outputs ──────────────────────────────────────────────────────────────────
output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }
output "pipeline_name"       { value = aws_codepipeline.app.name }
output "webhook_url"         { value = aws_codepipeline_webhook.github.url }
