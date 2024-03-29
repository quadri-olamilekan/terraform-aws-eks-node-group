data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "s3-eks-iam-roles-repo-12-source"
    key    = "eks/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_eks_node_group" "private-nodes" {
  cluster_name    = data.terraform_remote_state.network.outputs.cluster_name
  node_group_name = "private-nodes"
  node_role_arn   = data.terraform_remote_state.network.outputs.node_role

  subnet_ids = [
    for i in range(length(data.terraform_remote_state.network.outputs.private)) : data.terraform_remote_state.network.outputs.private[i]
  ]

  capacity_type  = "ON_DEMAND"
  instance_types = ["t2.medium"]


  scaling_config {
    desired_size = 2
    max_size     = 10
    min_size     = 0
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "private-node"
  }

  tags = {
    "k8s.io/cluster-autoscaler/${var.project}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"        = true
  }

}

/*
resource "aws_eks_node_group" "public-nodes" {
  depends_on      = [null_resource.aws_src_dst_checks]
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "public-nodes"
  node_role_arn   = module.eks-iam-roles.node_role

  subnet_ids = [
  for i in range(length(module.eks-vpc.public)) : module.eks-vpc.public[i]]

  capacity_type  = "ON_DEMAND"
  instance_types = ["t2.medium"]


  scaling_config {
    desired_size = 0
    max_size     = 10
    min_size     = 0
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "public-node"
  }

  tags = {
    "k8s.io/cluster-autoscaler/${var.project}" = "owned"
    "k8s.io/cluster-autoscaler/enabled"        = true
  }

}

*/

resource "null_resource" "eks_kubeconfig_updater" {

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.region} --name ${data.terraform_remote_state.network.outputs.cluster_name}"
  }
}

resource "null_resource" "node_ready" {
  depends_on = [aws_eks_node_group.private-nodes]

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      until kubectl get nodes --server=${data.terraform_remote_state.network.outputs.cluster_endpoint} -l role=private-node | grep 'Ready' &> /dev/null; do
        echo "Waiting for nodes with label 'role=private-node' to be ready..."
        sleep 10
      done

    EOT
  }
}

data "aws_iam_policy_document" "efs_csi_assume_role_policy" {
  count = var.create_role ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(data.terraform_remote_state.network.outputs.oidc-url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:efs-csi-controller-sa", "system:serviceaccount:kube-system:efs-csi-node-sa"]
    }

    principals {
      identifiers = [data.terraform_remote_state.network.outputs.oidc-arn]
      type        = "Federated"
    }
  }
}

# EFS CSI Driver Policy
# https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/master/docs/iam-policy-example.json
data "aws_iam_policy_document" "efs_csi" {
  count = var.create_role && var.attach_efs_csi_policy ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "elasticfilesystem:DescribeAccessPoints",
      "elasticfilesystem:DescribeFileSystems",
      "elasticfilesystem:DescribeMountTargets"
    ]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["elasticfilesystem:CreateAccessPoint"]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/efs.csi.aws.com/cluster"
      values   = ["true"]
    }
  }
  statement {
    effect    = "Allow"
    actions   = ["elasticfilesystem:TagResource"]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/efs.csi.aws.com/cluster"
      values   = ["true"]
    }
  }
  statement {
    effect    = "Allow"
    actions   = ["elasticfilesystem:DeleteAccessPoint"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/efs.csi.aws.com/cluster"
      values   = ["true"]
    }
  }
}

resource "aws_iam_policy" "efs_csi" {
  count  = var.create_role && var.attach_efs_csi_policy ? 1 : 0
  name   = "${var.project}-efs-csi-policy"
  policy = data.aws_iam_policy_document.efs_csi[0].json
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count      = var.create_role && var.attach_efs_csi_policy ? 1 : 0
  role       = aws_iam_role.efs_csi[0].name
  policy_arn = aws_iam_policy.efs_csi[0].arn
}

resource "aws_iam_role" "efs_csi" {
  count              = var.create_role ? 1 : 0
  name               = "${var.project}-efs-csi"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume_role_policy[0].json
}

resource "aws_eks_addon" "addons" {
  depends_on                  = [null_resource.node_ready]
  for_each                    = { for addon in var.addons : addon.name => addon }
  cluster_name                = data.terraform_remote_state.network.outputs.cluster_name
  addon_name                  = each.value.name
  addon_version               = each.value.version
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.efs_csi[0].arn
}

data "kubectl_file_documents" "install_autoscaler" {
  content = file("${path.module}/manifests/autoscaler.yaml")
}

resource "kubectl_manifest" "install_autoscaler" {
  depends_on = [null_resource.node_ready]
  for_each   = data.kubectl_file_documents.install_autoscaler.manifests
  yaml_body  = each.value
}


data "kubectl_file_documents" "argocd_namespace" {
  content = file("${path.module}/manifests/argocd-namespace.yaml")
}

resource "kubectl_manifest" "argocd_namespace" {
  depends_on = [kubectl_manifest.install_autoscaler]
  for_each   = data.kubectl_file_documents.argocd_namespace.manifests
  yaml_body  = each.value

  override_namespace = "argocd"
}


data "kubectl_file_documents" "install_argocd" {
  content = file("${path.module}/manifests/argocd-install.yaml")
}

resource "kubectl_manifest" "install_argocd" {
  depends_on         = [kubectl_manifest.argocd_namespace]
  for_each           = data.kubectl_file_documents.install_argocd.manifests
  yaml_body          = each.value
  override_namespace = "argocd"
}

data "kubectl_file_documents" "argocd_svc" {
  content = file("${path.module}/manifests/argocd-svc.yaml")
}

resource "kubectl_manifest" "argocd_svc" {
  depends_on         = [kubectl_manifest.install_argocd]
  for_each           = data.kubectl_file_documents.argocd_svc.manifests
  yaml_body          = each.value
  override_namespace = "argocd"
}

locals {
  istio_charts_url      = "https://istio-release.storage.googleapis.com/charts"
  prometheus_charts_url = "https://prometheus-community.github.io/helm-charts"
}

resource "kubernetes_namespace" "istio_system" {
  depends_on = [null_resource.node_ready]
  metadata {
    name = "istio-system"
  }
}

resource "kubernetes_namespace" "ml-app" {
  depends_on = [null_resource.node_ready]
  metadata {
    name = "ml-app"
  }
}

resource "kubernetes_labels" "ml-app-label" {
  depends_on  = [kubernetes_namespace.ml-app]
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = "ml-app"
  }
  labels = {
    istio-injection = "enabled"
  }
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  repository = local.istio_charts_url
  chart      = "base"

  timeout         = 120
  cleanup_on_fail = true
  force_update    = false
  namespace       = kubernetes_namespace.istio_system.metadata.0.name
  depends_on      = [kubernetes_namespace.istio_system]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = local.istio_charts_url
  chart      = "istiod"

  timeout         = 120
  cleanup_on_fail = true
  force_update    = false
  namespace       = kubernetes_namespace.istio_system.metadata.0.name

  set {
    name  = "meshConfig.accessLogFile"
    value = "/dev/stdout"
  }

  depends_on = [kubernetes_namespace.istio_system, helm_release.istio_base]
}

resource "helm_release" "istio_ingress" {
  name       = "istio-ingress"
  repository = local.istio_charts_url
  chart      = "gateway"

  timeout         = 500
  cleanup_on_fail = true
  force_update    = false
  namespace       = kubernetes_namespace.ml-app.metadata.0.name

  depends_on = [kubernetes_namespace.ml-app, helm_release.istiod]
}


resource "kubectl_manifest" "kiali" {
  depends_on         = [helm_release.istio_ingress]
  for_each           = data.kubectl_file_documents.kiali.manifests
  yaml_body          = each.value
  override_namespace = kubernetes_namespace.istio_system.metadata.0.name

}

data "kubectl_file_documents" "kiali" {
  content = file("${path.module}/manifests/kiali.yaml")
}

resource "kubectl_manifest" "prometheus" {
  for_each           = data.kubectl_file_documents.prometheus.manifests
  yaml_body          = each.value
  override_namespace = kubernetes_namespace.istio_system.metadata.0.name
  depends_on         = [kubectl_manifest.kiali]
}

data "kubectl_file_documents" "prometheus" {
  content = file("${path.module}/manifests/prometheus.yaml")
}


resource "kubectl_manifest" "grafana" {
  for_each           = data.kubectl_file_documents.grafana.manifests
  yaml_body          = each.value
  override_namespace = kubernetes_namespace.istio_system.metadata.0.name
  depends_on         = [kubectl_manifest.prometheus]
}

data "kubectl_file_documents" "grafana" {
  content = file("${path.module}/manifests/grafana.yaml")
}


resource "null_resource" "argo_repo_secret" {

  provisioner "local-exec" {
    command = "kubectl create -f ./argo-deployment/secret.yml  --server=${data.terraform_remote_state.network.outputs.cluster_endpoint}"
  }
  depends_on = [kubectl_manifest.grafana]
}

resource "null_resource" "argo_repo_deploy" {

  provisioner "local-exec" {
    command = "kubectl apply -f ./argo-deployment/deployment.yml  --server=${data.terraform_remote_state.network.outputs.cluster_endpoint}"
  }
  depends_on = [null_resource.argo_repo_secret]
}
