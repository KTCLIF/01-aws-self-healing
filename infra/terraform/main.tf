data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_count = 2
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  common_tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
    Purpose   = "resilience-lab"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "app" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + count.index)

  tags = {
    Name = "${var.project_name}-app-${local.azs[count.index]}"
    Tier = "app"
  }
}

resource "aws_subnet" "data" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20 + count.index)

  tags = {
    Name = "${var.project_name}-data-${local.azs[count.index]}"
    Tier = "data"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-public" }
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT is deliberately opt-in because NAT Gateways incur hourly and data charges.
# When enabled, each private app subnet uses the NAT Gateway in the same AZ.
resource "aws_eip" "nat" {
  count = var.nat_mode == "per_az" ? local.az_count : 0

  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-${local.azs[count.index]}" }
}

resource "aws_nat_gateway" "this" {
  count = var.nat_mode == "per_az" ? local.az_count : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${var.project_name}-nat-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "app" {
  count = local.az_count

  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.nat_mode == "per_az" ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[count.index].id
    }
  }

  tags = { Name = "${var.project_name}-app-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "app" {
  count = local.az_count

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# Data subnets intentionally have no internet default route.
resource "aws_route_table" "data" {
  count = local.az_count

  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-data-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "data" {
  count = local.az_count

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data[count.index].id
}
