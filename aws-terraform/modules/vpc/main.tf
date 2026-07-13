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
  count  = length(var.public_subnet_cidrs)
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

# NAT Instances (One per Availability Zone for High Availability)
resource "aws_instance" "nat" {
  count                       = length(var.public_subnet_cidrs)
  ami                         = data.aws_ami.nat_al2023_arm64.id
  instance_type               = "t4g.micro" # ARM64, extremely cost-effective
  subnet_id                   = aws_subnet.public[count.index].id
  associate_public_ip_address = true
  source_dest_check           = false # CRITICAL: allows the instance to forward traffic

  vpc_security_group_ids = [aws_security_group.nat.id]

  # User data to configure IP forwarding and iptables MASQUERADE
  user_data = <<-EOF
              #!/bin/bash
              # Enable IP forwarding
              echo 1 > /proc/sys/net/ipv4/ip_forward
              echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
              sysctl -p

              # Configure iptables to masquerade traffic
              PRIMARY_INTERFACE=$(ip route show | grep default | awk '{print $5}')
              iptables -t nat -A POSTROUTING -o $PRIMARY_INTERFACE -j MASQUERADE

              # Persist rules (on AL2023)
              dnf install -y iptables-services
              systemctl enable iptables
              systemctl start iptables
              iptables-save > /etc/sysconfig/iptables
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
  count         = length(var.public_subnet_cidrs)
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
  instance_id            = aws_instance.nat[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
