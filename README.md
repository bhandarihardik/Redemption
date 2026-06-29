# The Redemption - AWS EKS Platform

Production infrastructure and Helm chart for **The Redemption**, the global hotel point-deduction microservice. Built for Cloud Engineer technical assessment.

See 'docs/design-document.pdf' for the full architectural narrative, trade-off discussion, and team delegation plan. This README is the operational how-to-run-it companion.

## Repository structure

'''
terraform/
  modules/
    vpc/            3-tier VPC across 3 AZs (public / app / data subnets)
    eks/            EKS cluster, baseline node group, IRSA roles, Karpenter IAM + NodePool
    security/       Security groups implementing the default-deny network model
  environments/
    production/     Root module wiring the above + RDS, ElastiCache, WAF, Helm addons
helm/
  the-redemption/   The application Helm chart - the single source of truth for everything
                     that runs inside the cluster: baseline + burst Deployments, Service,
                     PDB, KEDA ScaledObject, NetworkPolicy, Istio mTLS/AuthorizationPolicy/
                     Gateway, and SLO-based PrometheusRule alerts. See values.yaml for the
                     full configuration surface.
argocd/
  application.yaml  GitOps Application - ArgoCD reconciles the cluster to match
                     helm/the-redemption + its values.yaml
.github/workflows/  CI for Terraform (plan-on-PR, gated apply) and the app (build/scan/push,
                     values.yaml image-tag bump, helm lint)
docs/
  design-document.pdf   Executive summary: architecture, trade-offs, team delegation
'''

## Why Helm over plain manifests / Kustomize

This is a single microservice with one production configuration, not a platform serving many
tenants with wildly different setups — Kustomize-style overlays would have been a perfectly
reasonable choice here too, and the design doc's trade-off table is explicit about that. The
chart is structured the way it is for two concrete reasons:

1. **One values.yaml as the base of truth.** A second environment (staging, a second region)
   is a small 'values-<env>.yaml' layered on top via ArgoCD's 'valueFiles', not a parallel
   manifest tree that silently drifts from the original.
2. **Shared template logic, not copy-pasted YAML.** The baseline and burst Deployments share
   probes, security context, and resource shape via '_helpers.tpl''s 'the-redemption.container'
   template — a probe path change is made once, not synced by hand across two files.

## Prerequisites

- Terraform >= 1.9
- AWS CLI v2, authenticated against the target account
- kubectl >= 1.30, Helm >= 3.15
- An S3 bucket + DynamoDB table for Terraform remote state (see Bootstrap, step 0)

## Bootstrap (first-time cluster creation)

**Step 0 - remote state backend.** Create the S3 bucket and DynamoDB lock table referenced in 'terraform/environments/production/providers.tf' out-of-band (a tiny separate Terraform config or a couple of AWS CLI calls - this can't bootstrap itself, since the backend needs to exist before 'terraform init' can use it).

**Step 1 - cluster only.**
'''bash
cd terraform/environments/production
terraform init
terraform apply -target=module.vpc -target=module.security -target=module.eks
'''

> **Why two stages, not one 'apply':** this config's 'kubernetes'/'kubectl'/'helm' Terraform providers are configured using the EKS cluster's own endpoint and CA cert. Terraform cannot resolve provider configuration that depends on a resource created in the *same* apply on a from-scratch run - this is a documented Terraform limitation, not a bug in this repo. Step 1 creates the cluster and OIDC provider only; step 2 below can then configure the providers correctly because the cluster already exists.

**Step 2 - everything else** (data layer, WAF, Karpenter NodePool CRDs, Helm-installed cluster addons like Istio/KEDA/Prometheus):
'''bash
terraform apply
'''

**Step 3 - point kubectl at the new cluster:**
'''bash
aws eks update-kubeconfig --name redemption-prod --region us-east-1
'''

**Step 4 - bootstrap ArgoCD itself** (one-time; ArgoCD isn't in Terraform deliberately - the chicken-and-egg between "the GitOps controller" and "the thing that installs the GitOps controller" is best broken manually once):
'''bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f argocd/application.yaml
'''

From this point forward, **no one runs 'helm upgrade' against the application by hand.** Every change to 'helm/the-redemption/values.yaml' lands via a merged PR, and ArgoCD's 'selfHeal: true' reconciles the cluster automatically - see 'argocd/application.yaml'.

## Local validation before opening a PR

'''bash
# Terraform
cd terraform/environments/production && terraform fmt -check -recursive && terraform validate

# Helm chart
helm lint helm/the-redemption
helm template the-redemption helm/the-redemption | kubectl apply --dry-run=client -f -
'''

CI ('.github/workflows/terraform-ci.yml') runs 'terraform validate', 'tfsec', and 'checkov' automatically on every PR touching 'terraform/**', and posts the plan as a PR comment. A failing security scan blocks the merge - it is not advisory. 'app-ci-cd.yml' runs 'helm lint' before any values.yaml change is committed.

### A note on how this chart was validated in this environment

The sandbox used to build this repo has no live AWS credentials and no outbound access to
'get.helm.sh' or any other Helm/Kubernetes release host, so a real 'helm template'/'helm lint'
could not be run here. Instead, every template was validated by:

- Hand-tracing the chart's 'include'/'dict'/'toYaml'/'nindent' patterns against the actual
  'values.yaml' to confirm the rendered output is structurally valid YAML
- Programmatically checking that every '{{ .Values.x.y }}' reference across all templates
  (74 references) resolves to a real key in 'values.yaml'
- Programmatically checking every '{{- if }}'/'{{- end }}' block is balanced, and every
  'include "name"' call resolves to a template actually defined in '_helpers.tpl'

Run 'helm lint helm/the-redemption' yourself as the first step after cloning, before anything
else - it's a 5-second command and the strongest signal that nothing was missed.

## Placeholders to fill in before a real deployment

This repo is intentionally explicit about what's a placeholder vs. a real value, rather than hiding assumptions:

| Placeholder | Where | Replace with |
|---|---|---|
| '<ECR_REPO_URL>' | helm/the-redemption/values.yaml, CI workflows | Actual ECR repository URI, output by a future 'aws_ecr_repository' resource (omitted here - assumed to pre-exist or be added trivially) |
| image.tag | helm/the-redemption/values.yaml | Populated automatically by 'app-ci-cd.yml' via 'yq' against the real Git SHA |
| '<ACCOUNT_ID>' | CI workflows | Target AWS account ID |
| '<TERRAFORM_OUTPUT:...>' | helm/the-redemption/values.yaml (config, serviceAccount.irsaRoleArn) | Wire via ArgoCD 'valueFiles' override generated from Terraform outputs, or a 'terraform_remote_state' data source if this moves to templated values |
| 'accor-redemption-tfstate-prod' | providers.tf | Real bucket name created in Bootstrap step 0 |
| 'redemption.accor-internal.com' | values.yaml (istio.gatewayHost) | Real internal DNS name, plus a matching ACM/cert-manager certificate |

## Team delegation (3 engineers: 1 Senior, 2 Juniors)

Full reasoning is in the design document; summary:

- **Senior** - 'terraform/modules/eks/*' (cluster, Karpenter, IRSA), the chart's Istio mTLS/AuthorizationPolicy templates, and KEDA scaling policy tuning. These are the pieces where a wrong default has the highest blast radius and the least forgiving failure mode.
- **Junior A** - 'terraform/modules/vpc', 'terraform/modules/security', and the WAF rules. Foundational but well-bounded: clear inputs/outputs, reviewable against a checklist, hard to get subtly wrong.
- **Junior B** - the chart's application templates (Deployment, Service, PDB, probes via '_helpers.tpl'), 'values.yaml' tuning, the 'PrometheusRule' alert definitions, and the CI/CD pipelines. High-learning-value work with a fast, visible feedback loop ('helm lint' fails immediately on a broken template).

Both juniors' work is reviewed by the senior before merge; the senior's own EKS/Istio/KEDA changes go through a second senior-level reviewer or, lacking one, an extra-long bake in a staging environment before production rollout.
