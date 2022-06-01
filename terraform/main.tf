provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks_blueprints.eks_cluster_id]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1alpha1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks_blueprints.eks_cluster_id]
    }
  }
}

data "aws_availability_zones" "available" {}

locals {
  name   = "test-flux-kms"
  region = "eu-west-1"

  cluster_version = "1.22"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Test = "1"
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.0.7"

  cluster_name    = local.name
  cluster_version = "1.22"

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  managed_node_groups = {
    mg_5 = {
      node_group_name = "test"
      instance_types  = ["m5.large"]
      subnet_type     = "private"
      subnet_ids      = module.vpc.private_subnets
      public_ip       = false

      k8s_labels = {
        environment = "test"
      }

      # Node Group scaling configuration
      desired_size = 1
      max_size     = 1
      min_size     = 1

      additional_tags = {
        subnet_type = "private"
      }
    }
  }

  node_security_group_additional_rules = {
    # Extend node-to-node security group rules. Recommended and required for the Add-ons
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Recommended outbound traffic for Node groups
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
    # Allows Control Plane Nodes to talk to Worker nodes on all ports. Added this to simplify the example and further avoid issues with Add-ons communication with Control plane.
    # This can be restricted further to specific port based on the requirement for each Add-on e.g., metrics-server 4443, spark-operator 8080, karpenter 8443 etc.
    # Change this according to your security requirements if needed
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  tags = local.tags
}

module "eks_blueprints_kubernetes_addons" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints//modules/kubernetes-addons?ref=v4.0.7"

  eks_cluster_id = module.eks_blueprints.eks_cluster_id

  # EKS Managed Add-ons
  enable_amazon_eks_coredns = true
  amazon_eks_coredns_config = {
    addon_version = "v1.8.7-eksbuild.1"
  }

  enable_amazon_eks_kube_proxy = true
  amazon_eks_kube_proxy_config = {
    addon_version = "v1.22.6-eksbuild.1"
  }

  enable_amazon_eks_vpc_cni = true
  amazon_eks_vpc_cni_config = {
    addon_version = "v1.11.0-eksbuild.1"
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Supporting Resources
#---------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 10)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/elb"              = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.name}" = "shared"
    "kubernetes.io/role/internal-elb"     = 1
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Flux KMS Resources
#---------------------------------------------------------------
data "aws_kms_alias" "cluster" {
  name = "alias/${local.name}"
  depends_on = [module.eks_blueprints]
}

resource "aws_iam_policy" "kms-decrypt" {
  name        = "${local.name}-kms-decrypt"
  path        = "/"
  description = "Allow KMS decrypt for ${local.name} EKS cluster"

  policy = jsonencode({
    "Version" = "2012-10-17",
    "Statement" = [
        {
            "Action" = [
                "kms:Decrypt",
                "kms:DescribeKey"
            ],
            "Effect" = "Allow",
            "Resource" = [
              data.aws_kms_alias.cluster.arn,
              data.aws_kms_alias.cluster.target_key_arn,
            ]
        }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role" "decrypt-secrets" {
  name = "decrypt-${local.name}-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Federated = module.eks_blueprints.eks_oidc_provider_arn
        }
        Condition = {
          StringEquals = {
              "${replace(module.eks_blueprints.eks_oidc_provider_arn, "/arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:sub" = "system:serviceaccount:flux-system:kustomize-controller",
              "${replace(module.eks_blueprints.eks_oidc_provider_arn, "/arn:aws:iam::[0-9]+:oidc-provider\\//", "")}:aud" = "sts.amazonaws.com"
          }
        }
      },
    ]
  })

  managed_policy_arns = [aws_iam_policy.kms-decrypt.arn]

  tags = local.tags
}