output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = module.eks_blueprints.configure_kubectl
}

output "decrypt_secrets_role" {
  description = "Role ARN for secrets decryption"
  value = aws_iam_role.decrypt-secrets.arn
}

output "decrypt_kms_key" {
  description = "Key ARM for secrets decryption"
  value = data.aws_kms_alias.cluster.arn
}