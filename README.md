# EKS Demo App — Docker + GitHub + AWS CodePipeline + EKS

A minimal Node.js app deployed end-to-end through:
**GitHub → AWS CodePipeline → CodeBuild (Docker + ECR) → EKS**

---

## Project structure

```
.
├── src/index.js          # Express app
├── Dockerfile            # Multi-stage Docker build
├── buildspec.yml         # CodeBuild instructions
├── k8s/
│   ├── deployment.yaml   # EKS Deployment (2 replicas)
│   └── service.yaml      # LoadBalancer Service + Namespace
└── terraform/
    ├── main.tf           # ECR, CodeBuild, CodePipeline, IAM, Webhook
    └── eks.tf            # EKS cluster + VPC (via community modules)
```

---

## Prerequisites

| Tool | Version |
|------|---------|
| AWS CLI | v2 |
| Terraform | >= 1.6 |
| kubectl | >= 1.28 |
| Docker | >= 24 |
| Node.js | >= 20 |

- AWS account with permissions to create EKS, ECR, CodePipeline, IAM, VPC
- GitHub personal access token (repo + admin:repo_hook scopes)

---

## Quick start

### 1 — Clone & configure

```bash
git clone https://github.com/<YOUR_ORG>/eks-demo-app.git
cd eks-demo-app
```

### 2 — Provision EKS + pipeline with Terraform

```bash
cd terraform
terraform init

terraform apply \
  -var="github_owner=<YOUR_GH_USER>" \
  -var="github_repo=eks-demo-app" \
  -var="github_oauth_token=<YOUR_PAT>"
```

This creates:
- VPC with public/private subnets across 2 AZs
- EKS cluster (`demo-cluster`, 2 × t3.medium nodes)
- ECR repository (`eks-demo-app`)
- CodeBuild project with Docker-in-Docker + kubectl
- CodePipeline (Source → Build & Deploy stages)
- GitHub webhook (push to `main` triggers pipeline)

### 3 — Register the webhook in GitHub

Copy `webhook_url` from Terraform output, then run:

```bash
# GitHub CLI
gh api repos/<OWNER>/<REPO>/hooks --method POST \
  -f name=web \
  -f "config[url]=<WEBHOOK_URL>" \
  -f "config[content_type]=json" \
  -f "config[secret]=<WEBHOOK_SECRET>" \
  -F active=true \
  -f "events[]=push"
```

### 4 — Push and watch

```bash
git add . && git commit -m "initial deploy" && git push origin main
```

Monitor in the AWS console:  
**CodePipeline → eks-demo-pipeline** (Source → Build & Deploy)

### 5 — Access the app

```bash
aws eks update-kubeconfig --region us-east-1 --name demo-cluster
kubectl get svc demo-app-svc -n demo
# Copy EXTERNAL-IP and open in browser
```

---

## How it works — pipeline flow

```
git push
  └─▶ GitHub webhook
        └─▶ CodePipeline (Source stage)
              └─▶ CodeBuild (Build & Deploy stage)
                    ├─ npm test
                    ├─ docker build → tag with git SHA
                    ├─ docker push → ECR
                    ├─ aws eks update-kubeconfig
                    ├─ sed image tag into k8s/deployment.yaml
                    └─ kubectl apply -f k8s/
                          └─▶ EKS rolling update (0 downtime)
```

---

## Local development

```bash
# Run without Docker
npm install && npm start

# Run with Docker
docker build -t eks-demo-app .
docker run -p 3000:3000 eks-demo-app

curl http://localhost:3000/
curl http://localhost:3000/health
```

---

## IAM notes

CodeBuild needs two permissions that are often forgotten:
1. `ecr:GetAuthorizationToken` on `*` (cannot be scoped to a repo)
2. EKS access entry with `AmazonEKSClusterAdminPolicy` — added via `access_entries` in `eks.tf`

The cluster RBAC is handled by EKS access entries (new in EKS 1.28), not the old `aws-auth` ConfigMap.

---

## Clean up

```bash
kubectl delete namespace demo        # remove K8s resources first
cd terraform && terraform destroy    # destroy AWS infrastructure
```
