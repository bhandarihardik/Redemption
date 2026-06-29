# ---------------------------------------------------------------------------
# Karpenter — burst/spike compute lane (lane 2 of 2)
#
# Why Karpenter for the 10x flash-sale requirement specifically:
#   - Reacts to PENDING POD resource requests directly, not to a CloudWatch
#     metric on an ASG. The moment KEDA creates new pod replicas that can't
#     schedule, Karpenter sees the unschedulable pods and provisions a
#     right-sized node immediately — typically under 60 seconds from
#     "pod pending" to "node Ready". A traditional ASG + Cluster Autoscaler
#     path is slower because it scales pre-defined instance-type ASGs
#     reactively off lagging metrics.
#   - Bin-packs efficiently and picks the cheapest instance type that fits
#     the pending pods, mixing spot and on-demand automatically via the
#     NodePool's 'capacity-type' requirement below.
#   - Consolidates aggressively after the spike ends ('consolidationPolicy:
#     WhenEmptyOrUnderutilized'), so we are not paying flash-sale prices for
#     flash-sale capacity at 3am on a Tuesday.
# ---------------------------------------------------------------------------

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${var.name}-karpenter-controller-policy"
  role = aws_iam_role.irsa["karpenter"].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceActions"
        Effect = "Allow"
        Resource = "*"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSpotPriceHistory",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
        ]
      },
      {
        Sid      = "AllowPricingRead"
        Effect   = "Allow"
        Resource = "*"
        Action   = ["pricing:GetProducts", "ssm:GetParameter"]
      },
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Resource = aws_iam_role.baseline_nodes.arn # Karpenter-launched nodes reuse the same scoped node role
        Action   = "iam:PassRole"
      },
      {
        Sid      = "AllowInterruptionQueueAccess"
        Effect   = "Allow"
        Resource = aws_sqs_queue.karpenter_interruption.arn
        Action   = ["sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
      },
    ]
  })
}

# Karpenter consumes EC2 Spot interruption notices via this queue, giving
# pods ~2 minutes of warning before a spot node is reclaimed — Karpenter
# cordons/drains proactively instead of the node disappearing under load.
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.name}-karpenter-interruption"
  message_retention_seconds = 300
  tags                      = var.tags
}

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name = "${var.name}-karpenter-spot-interruption"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning", "EC2 Instance Rebalance Recommendation"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

# ---------------------------------------------------------------------------
# Karpenter Kubernetes resources (EC2NodeClass + NodePool) — applied via the
# kubernetes provider so they live in the same 'terraform apply' as the
# cluster. In a real Day-2 setup these are usually moved into the ArgoCD
# app-of-apps; kept here for assessment self-containment.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: redemption-burst
    spec:
      amiFamily: AL2023
      role: ${aws_iam_role.baseline_nodes.name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.name}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 50Gi
            volumeType: gp3
            encrypted: true
      metadataOptions:
        httpTokens: required        # IMDSv2 enforced — blocks SSRF-to-credential-theft path
        httpPutResponseHopLimit: 1
  YAML

  depends_on = [aws_eks_node_group.baseline]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: redemption-burst
    spec:
      template:
        metadata:
          labels:
            workload-tier: burst
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: redemption-burst
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["m6i.large", "m6i.xlarge", "m5.large", "m5.xlarge", "c6i.large", "c6i.xlarge"]
          taints:
            - key: workload-tier
              value: burst
              effect: NoSchedule  # burst pods must explicitly tolerate this; baseline pods never land on spot
      limits:
        cpu: 200      # hard ceiling — caps the worst-case bill during a runaway scaling loop
        memory: 800Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 60s
  YAML

  depends_on = [kubectl_manifest.karpenter_node_class]
}
