resource "aws_eks_node_group" "private-nodes" {
  depends_on      = [null_resource.aws_src_dst_checks]
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "private-nodes"
  node_role_arn   = module.eks-iam-roles.node_role

  subnet_ids = [
    for i in range(length(module.eks-vpc.private)) : module.eks-vpc.private[i]
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


data "external" "thumbprint" {
  program = ["${path.module}/thumbprint.sh", var.region, "eks", "oidc-thumbprint", "--issuer-url", aws_eks_cluster.cluster.identity[0].oidc[0].issuer]
}

data "aws_iam_policy_document" "oidc_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:default:eks"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "oidc" {
  depends_on         = [aws_iam_openid_connect_provider.eks]
  assume_role_policy = data.aws_iam_policy_document.oidc_assume_role_policy.json
  name               = "eks-oidc"
}

resource "aws_iam_policy" "oidc-policy" {
  name = "eks-oidc-policy"

  policy = jsonencode({
    Statement = [{
      Action = ["*"
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "oidc_attach" {
  depends_on = [aws_iam_role.oidc]
  role       = aws_iam_role.oidc.name
  policy_arn = aws_iam_policy.oidc-policy.arn
}

resource "aws_iam_openid_connect_provider" "eks" {
  depends_on      = [aws_eks_cluster.cluster]
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.external.thumbprint.result.thumbprint]
  url             = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}


data "aws_iam_policy_document" "eks_cluster_autoscaler_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "eks_cluster_autoscaler" {
  depends_on         = [aws_iam_role.oidc]
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_autoscaler_assume_role_policy.json
  name               = "eks-cluster-autoscaler"
}

resource "aws_iam_policy" "eks_cluster_autoscaler" {
  name = "eks-cluster-autoscaler"

  policy = jsonencode({
    Statement = [{
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeInstanceTypes"
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_autoscaler_attach" {
  depends_on = [aws_iam_role.eks_cluster_autoscaler]
  role       = aws_iam_role.eks_cluster_autoscaler.name
  policy_arn = aws_iam_policy.eks_cluster_autoscaler.arn
}

resource "null_resource" "node_ready" {
  depends_on = [aws_eks_node_group.private-nodes]

  provisioner "local-exec" {
    command = <<-EOT
      #!/bin/bash
      until kubectl get nodes --server=${aws_eks_cluster.cluster.endpoint} -l role=private-node | grep 'Ready' &> /dev/null; do
        echo "Waiting for nodes with label 'role=private-node' to be ready..."
        sleep 10
      done

    EOT
  }
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
  istio_charts_url = "https://istio-release.storage.googleapis.com/charts"
}

resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
  }
}

resource "helm_release" "istio-base" {
  repository      = local.istio_charts_url
  chart           = "base"
  name            = "istio-base"
  namespace       = kubernetes_namespace.istio_system.id
  cleanup_on_fail = true
  force_update    = false

  depends_on = [kubernetes_namespace.istio_system]
}

resource "helm_release" "istiod" {
  repository      = local.istio_charts_url
  chart           = "istiod"
  name            = "istiod"
  namespace       = kubernetes_namespace.istio_system.id
  cleanup_on_fail = true
  force_update    = false

  depends_on = [helm_release.istio-base]
}


resource "kubernetes_labels" "default" {
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = "default"
  }
  labels = {
    istio-injection = "enabled"
  }
}

resource "kubectl_manifest" "kiali" {
  for_each           = data.kubectl_file_documents.kiali.manifests
  yaml_body          = each.value
  override_namespace = "istio-system"

  #depends_on = [helm_release.istio_ingress]
}

data "kubectl_file_documents" "kiali" {
  content = file("${path.module}/manifests/kiali.yaml")
}

resource "kubectl_manifest" "prometheus" {
  for_each           = data.kubectl_file_documents.prometheus.manifests
  yaml_body          = each.value
  override_namespace = "istio-system"

  depends_on = [kubectl_manifest.kiali]
}

data "kubectl_file_documents" "prometheus" {
  content = file("${path.module}/manifests/prometheus.yaml")
}


resource "helm_release" "istio_ingress" {
  name             = "istio-ingressgateway"
  chart            = "gateway"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  namespace        = "istio-ingress"
  create_namespace = true

  version = "1.20.2"

  set {
    name  = "service.type"
    value = "NodePort"
  }

  set {
    name  = "service.ports[0].name"
    value = "status-port"
  }

  set {
    name  = "service.ports[0].port"
    value = 15021
  }

  set {
    name  = "service.ports[0].targetPort"
    value = 15021
  }

  set {
    name  = "service.ports[0].nodePort"
    value = 30021
  }

  set {
    name  = "service.ports[0].protocol"
    value = "TCP"
  }

  set {
    name  = "service.ports[1].name"
    value = "http2"
  }

  set {
    name  = "service.ports[1].port"
    value = 80
  }

  set {
    name  = "service.ports[1].targetPort"
    value = 80
  }

  set {
    name  = "service.ports[1].nodePort"
    value = 30080
  }

  set {
    name  = "service.ports[1].protocol"
    value = "TCP"
  }


  set {
    name  = "service.ports[2].name"
    value = "https"
  }

  set {
    name  = "service.ports[2].port"
    value = 443
  }

  set {
    name  = "service.ports[2].targetPort"
    value = 443
  }

  set {
    name  = "service.ports[2].nodePort"
    value = 30443
  }

  set {
    name  = "service.ports[2].protocol"
    value = "TCP"
  }

  depends_on = [
    aws_eks_cluster.cluster,
    aws_eks_node_group.private-nodes,
    helm_release.istio-base,
    helm_release.istiod
  ]
}
