data "aws_route53_zone" "this" {
  name = var.domain_name
}

data "aws_availability_zones" "available" {}

locals {
  name  = var.name == "" ? "cbci-bp01" : "cbci-bp01-${var.name}"
  region = var.region

  vpc_name             = "${local.name}-vpc"
  cluster_name         = "${local.name}-eks"
  kubeconfig_file      = "kubeconfig_${local.name}.yaml"
  kubeconfig_file_path = abspath("${path.root}/${local.kubeconfig_file}")

  vpc_cidr = "10.0.0.0/16"

  #https://docs.cloudbees.com/docs/cloudbees-common/latest/supported-platforms/cloudbees-ci-cloud#_kubernetes
  k8s_version = "1.27"

  route53_zone_id  = data.aws_route53_zone.this.id
  route53_zone_arn = data.aws_route53_zone.this.arn
  #Number of AZs per region https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  cjoc_url = "https://cjoc.${var.domain_name}"

  tags = merge(var.tags, {
    "tf:blueprint"  = local.name
    "tf:repository" = "github.com/cloudbees/terraform-aws-cloudbees-ci-eks-addon"
  })
}

################################################################################
# EKS: Add-ons
################################################################################

module "eks_blueprints_addon_cbci" {
  source = "../../"

  hostname     = var.domain_name
  cert_arn     = module.acm.acm_certificate_arn
  temp_license = var.temp_license

  depends_on = [
    module.eks_blueprints_addons
  ]
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.12.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  cluster_version   = module.eks.cluster_version

  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns    = {}
    vpc-cni    = {}
    kube-proxy = {}
  }

  enable_external_dns = true
  external_dns = {
    values = [templatefile("${path.module}/extdns-values.yml", {
      zoneDNS = var.domain_name
    })]
  }
  external_dns_route53_zone_arns      = [local.route53_zone_arn]
  enable_aws_load_balancer_controller = true

  tags = local.tags
}

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.29.0"

  role_name_prefix = "${module.eks.cluster_name}-ebs-csi-driv"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = var.tags
}

################################################################################
# EKS: Infra
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

  cluster_name                   = local.cluster_name
  cluster_version                = local.k8s_version
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Security groups based on the best practices doc https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html.
  #   So, by default the security groups are restrictive. Users needs to enable rules for specific ports required for App requirement or Add-ons
  #   See the notes below for each rule used in these examples
  node_security_group_additional_rules = {
    # Recommended outbound traffic for Node groups
    egress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      self        = true
    }
    # Extend node-to-node security group rules. Recommended and required for the Add-ons
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }

    egress_ssh_all = {
      description      = "Egress all ssh to internet for github"
      protocol         = "tcp"
      from_port        = 22
      to_port          = 22
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

  eks_managed_node_groups = {
    mg_start = {
      node_group_name = "managed-start"
      instance_types  = ["m5d.4xlarge"]
      capacity_type   = "ON_DEMAND"
      disk_size       = 25
      desired_size    = 2
    }
  }

  tags = local.tags
}

resource "null_resource" "create_kubeconfig" {

  depends_on = [module.eks]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region} --kubeconfig ${local.kubeconfig_file}"
  }
}

################################################################################
# Supported Resources
################################################################################

module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "4.3.2"

  #Important: Application Services Hostname must be the same as the domain name or subject_alternative_names
  domain_name = var.domain_name
  subject_alternative_names = [
    "*.${var.domain_name}" # For subdomains example.${var.domain_name}
  ]

  #https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html
  zone_id = local.route53_zone_id

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = local.vpc_name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  #https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html
  #https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags

}
