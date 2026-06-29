# ---------------------------------------------------------------------------
# WAF — Layer 1 of the Defense-in-Depth model (edge)
#
# Attached to the ALB. Combines AWS managed rule groups (common exploits,
# bad IPs) with a custom rate-based rule. The rate-based rule is the direct
# mitigation for "flash sale traffic spike" being indistinguishable from
# "credential-stuffing / scalper-bot traffic spike" at the edge — both look
# like a sudden surge from many IPs. We rate-limit per-IP, not in aggregate,
# so the legitimate flash-sale spike (many different customers) passes
# through untouched while a concentrated bot source gets throttled.
# ---------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "main" {
  name        = "${var.cluster_name}-waf"
  description = "Edge protection for The Redemption public ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-CommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-KnownBadInputs"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000 # requests per 5-min window per IP — generous for a real shopper retrying a purchase, punishing for a scraper/bot
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.cluster_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = local.common_tags
}
