# ---------------------------------------------------------------------------
# VPC — 3-tier network across 3 AZs (public / private-app / private-data)
#
# Design rationale:
#   - 3 AZs minimum: losing one AZ during a flash-sale spike must not take
#     capacity below a survivable threshold (67% remaining vs 50% with 2 AZs).
#   - One NAT Gateway PER AZ (not one shared NAT): a single NAT GW is a
#     hidden single point of failure for all egress traffic (image pulls,
#     external API calls, license checks). Cost is ~3x but this is a
#     revenue-critical service, so we pay for it.
#   - Three subnet tiers, not two:
#       public          -> ALB / NAT only, nothing else ever lives here
#       private-app     -> EKS worker nodes / pods
#       private-data     -> RDS, ElastiCache (no route to the internet at all)
#     This tier separation is what makes "least privilege at the network
#     layer" actually enforceable later via NACLs + security groups, instead
#     of being a paper policy.
# ---------------------------------------------------------------------------

locals {
  az_count = length(var.azs)

  # /20 per tier per AZ out of a /16 -> plenty of IPs for EKS (each pod can
  # consume an ENI-backed IP under the VPC CNI), still leaves room to grow.
  public_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  app_subnet_cidrs     = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 4)]
  data_subnet_cidrs    = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

# ---------------------------------------------------------------------------
# Public tier — ALB + NAT Gateways only
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                          = "${var.name}-public-${var.azs[count.index]}"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${var.name}"           = "shared"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id              = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One EIP + NAT Gateway per AZ — see rationale above (no shared NAT).
resource "aws_eip" "nat" {
  count  = local.az_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-eip-${var.azs[count.index]}" })
}

resource "aws_nat_gateway" "main" {
  count         = local.az_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${var.azs[count.index]}" })

  depends_on = [aws_internet_gateway.main]
}

# ---------------------------------------------------------------------------
# Private tier — EKS worker nodes / application pods
# ---------------------------------------------------------------------------
resource "aws_subnet" "app" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, {
    Name                                          = "${var.name}-app-${var.azs[count.index]}"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${var.name}"           = "shared"
    # Karpenter discovers subnets via this tag — see eks module.
    "karpenter.sh/discovery"                      = var.name
  })
}

resource "aws_route_table" "app" {
  count  = local.az_count
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name}-app-rt-${var.azs[count.index]}" })
}

# Each AZ's app subnet egresses through ITS OWN AZ's NAT Gateway. This keeps
# a NAT Gateway failure scoped to a single AZ instead of fanning out.
resource "aws_route" "app_nat" {
  count                  = local.az_count
  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id          = aws_nat_gateway.main[count.index].id
}

resource "aws_route_table_association" "app" {
  count          = local.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# ---------------------------------------------------------------------------
# Private tier — data layer (RDS, ElastiCache). No internet route at all.
# ---------------------------------------------------------------------------
resource "aws_subnet" "data" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.data_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, { Name = "${var.name}-data-${var.azs[count.index]}" })
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name}-data-rt" })
}

resource "aws_route_table_association" "data" {
  count          = local.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# ---------------------------------------------------------------------------
# VPC Flow Logs — required for the "Defense in Depth" / audit story in the
# design doc, and genuinely useful for diagnosing the AZ-outage failure mode.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.name}-flow-logs"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.name}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.name}-vpc-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "main" {
  iam_role_arn         = aws_iam_role.flow_logs.arn
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  traffic_type         = "REJECT" # capture denied traffic for security review; ACCEPT logs are high-volume/low-signal
  vpc_id               = aws_vpc.main.id
  max_aggregation_interval = 60
  tags                 = var.tags
}
