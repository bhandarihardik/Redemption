# ---------------------------------------------------------------------------
# Cluster addons via Helm — installed in this same root module for assessment
# self-containment. In steady-state Day-2 operations these move under
# ArgoCD (see k8s/base/argocd and design doc section E) so addon upgrades
# go through the same GitOps review path as application changes, instead
# of living in a separate Terraform-applied silo that drifts from Git.
# ---------------------------------------------------------------------------

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.0.6"

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.irsa_role_arns["karpenter"]
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "500m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "512Mi"
  }

  depends_on = [module.eks]
}

resource "helm_release" "aws_lb_controller" {
  name             = "aws-load-balancer-controller"
  namespace        = "kube-system"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.8.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.irsa_role_arns["lb-controller"]
  }

  depends_on = [module.eks]
}

# KEDA — application-level autoscaling. Chosen over plain HPA for the
# scalability strategy because KEDA can scale on metrics OUTSIDE the cluster
# (SQS queue depth, ALB request count via CloudWatch, custom Prometheus
# queries) and crucially supports scaling from/to zero on auxiliary workers,
# while HPA is limited to metrics already in the metrics-server/custom
# metrics API and cannot scale to zero. The primary Redemption API pods
# still scale 3..N (never to zero, see KEDA ScaledObject minReplicaCount in
# k8s/base), but background point-reconciliation workers legitimately can.
resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.15.1"

  depends_on = [module.eks]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.3"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.irsa_role_arns["external-secrets"]
  }

  depends_on = [module.eks]
}

# Istio — service mesh for mTLS between pods (Layer 3 of defense in depth)
# and the ingress gateway that terminates the ALB connection. Chosen over
# "just use NetworkPolicy" because the requirement is encrypted east-west
# traffic + fine-grained AuthorizationPolicy (which service can call which
# service, independent of IP/CIDR), not just L3/L4 segmentation.
resource "helm_release" "istio_base" {
  name       = "istio-base"
  namespace  = "istio-system"
  create_namespace = true
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = "1.23.0"

  depends_on = [module.eks]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  namespace  = "istio-system"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = "1.23.0"

  depends_on = [helm_release.istio_base]
}

resource "helm_release" "istio_ingress" {
  name             = "istio-ingressgateway"
  namespace        = "istio-ingress"
  create_namespace = true
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = "1.23.0"

  depends_on = [helm_release.istiod]
}

# kube-prometheus-stack — Prometheus + Grafana + Alertmanager in one chart,
# the de facto standard for cluster + app metrics. Justified in full in the
# design doc's Observability section.
resource "random_password" "grafana_admin" {
  length  = 24
  special = true
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name = "${var.cluster_name}/grafana-admin-password"
  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id     = aws_secretsmanager_secret.grafana_admin.id
  secret_string = random_password.grafana_admin.result
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "62.5.1"

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        retention = "15d"
        resources = {
          requests = { cpu = "500m", memory = "2Gi" }
        }
      }
    }
    grafana = {
      adminPassword = random_password.grafana_admin.result # also persisted in Secrets Manager above for retrieval by operators; never committed to git
    }
  })]

  depends_on = [module.eks]
}
