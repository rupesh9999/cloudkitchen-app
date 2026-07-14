# =============================================================================
# vpc module
# =============================================================================
# Builds the network foundation for the CloudKitchen EKS platform:
#   * 1 VPC with DNS support/hostnames enabled
#   * 3 public subnets  (one per AZ) - host the NAT gateways, bastion, public LBs
#   * 3 private subnets (one per AZ) - host the EKS worker nodes
#   * Internet Gateway for public egress/ingress
#   * NAT gateway(s) for private subnet egress (single or per-AZ)
#   * Public + private route tables and associations
#
# Subnets carry the EKS discovery tags so that the AWS Load Balancer Controller
# and the cluster can place public (elb) and internal (internal-elb) load
# balancers in the right tier.
# =============================================================================

locals {
  # Shared tag every subnet/VPC needs so EKS recognises owned resources.
  cluster_shared_tag = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  nat_count = var.single_nat_gateway ? 1 : length(var.public_subnet_cidrs)
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, local.cluster_shared_tag, {
    Name = "${var.name_prefix}-vpc"
  })
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

# -----------------------------------------------------------------------------
# Public subnets
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, local.cluster_shared_tag, {
    Name                     = "${var.name_prefix}-public-${var.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
    Tier                     = "public"
  })
}

# -----------------------------------------------------------------------------
# Private subnets
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, local.cluster_shared_tag, {
    Name                              = "${var.name_prefix}-private-${var.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
    Tier                              = "private"
  })
}

# -----------------------------------------------------------------------------
# NAT Instances (ARM64 cost-saving alternative to NAT Gateways)
# -----------------------------------------------------------------------------

# Dynamic lookup for the latest Amazon Linux 2023 ARM64 AMI
data "aws_ami" "nat_al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Elastic IPs for the NAT Instances
resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-eip-${count.index}"
  })

  depends_on = [aws_internet_gateway.this]
}

# Security group for NAT instances
resource "aws_security_group" "nat" {
  name        = "${var.name_prefix}-nat-sg"
  description = "Security group for NAT instances"
  vpc_id      = aws_vpc.this.id

  # Allow all outbound traffic to the internet
  egress {
    description = "Allow all outbound traffic to internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all inbound traffic from VPC/private subnets
  ingress {
    description = "Allow inbound traffic from VPC CIDR"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-sg"
  })
}

# NAT Instances (One per Availability Zone or a Single Instance for Cost Savings)
resource "aws_instance" "nat" {
  count                       = local.nat_count
  ami                         = data.aws_ami.nat_al2023_arm64.id
  instance_type               = "t4g.micro" # ARM64, extremely cost-effective
  subnet_id                   = aws_subnet.public[count.index].id
  associate_public_ip_address = true
  source_dest_check           = false # CRITICAL: allows the instance to forward traffic

  vpc_security_group_ids = [aws_security_group.nat.id]

  # User data to configure IP forwarding and iptables MASQUERADE
  user_data = <<-EOF
    #!/bin/bash
    set -ex

    # Enable IP forwarding (immediate + persistent)
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-nat.conf

    # Wait for default route to be available
    for i in $(seq 1 30); do
      PRIMARY_INTERFACE=$(ip -o -4 route show default | awk '{print $5}' | head -1)
      [ -n "$PRIMARY_INTERFACE" ] && break
      sleep 2
    done

    if [ -z "$PRIMARY_INTERFACE" ]; then
      echo "ERROR: No default route found after 60s" >&2
      exit 1
    fi

    echo "Configuring NAT masquerade on interface: $PRIMARY_INTERFACE"

    # Flush any existing NAT rules and add masquerade
    iptables -t nat -F POSTROUTING
    iptables -t nat -A POSTROUTING -o "$PRIMARY_INTERFACE" -j MASQUERADE

    # Verify the rule is active
    iptables -t nat -L POSTROUTING -v -n
    echo "NAT masquerade configured successfully"
    EOF

  # Encrypted gp3 root block device
  root_block_device {
    encrypted   = true
    volume_size = 8
    volume_type = "gp3"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-${count.index}"
  })
}

# Associate Elastic IPs with the NAT instances
resource "aws_eip_association" "nat" {
  count         = local.nat_count
  instance_id   = aws_instance.nat[count.index].id
  allocation_id = aws_eip.nat[count.index].id
}

# Commented out managed NAT Gateway resources:
# locals {
#   nat_gateway_count = var.single_nat_gateway ? 1 : length(var.public_subnet_cidrs)
# }
#
# resource "aws_nat_gateway" "this" {
#   count = local.nat_gateway_count
#
#   allocation_id = aws_eip.nat[count.index].id
#   # NAT gateways always live in public subnets.
#   subnet_id = aws_subnet.public[count.index].id
#
#   tags = merge(var.tags, {
#     Name = "${var.name_prefix}-nat-${count.index}"
#   })
#
#   depends_on = [aws_internet_gateway.this]
# }

# -----------------------------------------------------------------------------
# Public route table (one, shared by all public subnets)
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Private route tables (one per AZ so each can target its local NAT)
# -----------------------------------------------------------------------------
resource "aws_route_table" "private" {
  count  = length(aws_subnet.private)
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-rt-${var.azs[count.index]}"
  })
}

resource "aws_route" "private_nat" {
  count                  = length(aws_route_table.private)
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[var.single_nat_gateway ? 0 : count.index].primary_network_interface_id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# -----------------------------------------------------------------------------
# VPC Endpoints — allow EKS worker nodes to bootstrap without NAT dependency
# -----------------------------------------------------------------------------
# Security group for interface VPC endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "Security group for VPC interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpce-sg"
  })
}

# S3 Gateway Endpoint (FREE — no hourly charges)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-s3-vpce"
  })
}

# ECR API Interface Endpoint (image manifest lookups)
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ecr-api-vpce"
  })
}

# ECR Docker Interface Endpoint (image pulls)
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ecr-dkr-vpce"
  })
}

# STS Interface Endpoint (IAM authentication for EKS)
resource "aws_vpc_endpoint" "sts" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-sts-vpce"
  })
}
