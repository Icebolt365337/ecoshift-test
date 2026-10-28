output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.github.arn
}
