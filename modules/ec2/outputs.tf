output "security_group_id" {
  description = "ID of the EC2 security group"
  value       = aws_security_group.ec2.id
}

output "iam_role_arn" {
  description = "ARN of the EC2 IAM role"
  value       = aws_iam_role.ec2.arn
}

output "instance_profile_name" {
  description = "Name of the EC2 instance profile"
  value       = aws_iam_instance_profile.ec2.name
}

output "instance_ids" {
  description = "IDs of the EC2 instances"
  value       = aws_instance.main[*].id
}

output "instance_public_ips" {
  description = "Public IP addresses of EC2 instances"
  value       = aws_instance.main[*].public_ip
}

output "instance_private_ips" {
  description = "Private IP addresses of EC2 instances"
  value       = aws_instance.main[*].private_ip
}

output "instance_public_dns" {
  description = "Public DNS names of EC2 instances"
  value       = aws_instance.main[*].public_dns
}

output "elastic_ips" {
  description = "Elastic IP addresses assigned to EC2 instances"
  value       = aws_eip.ec2[*].public_ip
}

output "ami_id_used" {
  description = "AMI ID used for the EC2 instances"
  value       = coalesce(var.ami_id, data.aws_ami.amazon_linux_2023.id)
}

output "launch_template_id" {
  description = "ID of the launch template"
  value       = aws_launch_template.main.id
}

output "launch_template_latest_version" {
  description = "Latest version of the launch template"
  value       = aws_launch_template.main.latest_version
}

output "ssh_commands" {
  description = "SSH commands to connect to the instances"
  value = [
    for i, inst in aws_instance.main :
    "ssh -i <your-key.pem> ec2-user@${length(aws_eip.ec2) > i ? aws_eip.ec2[i].public_ip : inst.public_ip}"
  ]
}
