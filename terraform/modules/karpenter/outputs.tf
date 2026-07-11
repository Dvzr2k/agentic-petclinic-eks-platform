output "karpenter_role_arn" {
  description = "ARN of the Karpenter controller's IRSA role, annotated on the karpenter ServiceAccount"
  value       = aws_iam_role.karpenter.arn
}

output "karpenter_queue_name" {
  description = "Name of the SQS interruption queue Karpenter listens on"
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "karpenter_instance_profile_name" {
  description = "Name of the instance profile attached to Karpenter-launched nodes"
  value       = aws_iam_instance_profile.karpenter_node.name
}
