output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = aws_db_instance.fleetlm.endpoint
}

output "rds_address" {
  description = "RDS instance address (hostname only)"
  value       = aws_db_instance.fleetlm.address
}

output "database_url" {
  description = "Full DATABASE_URL for FleetLM"
  value       = "ecto://${var.db_username}:${var.db_password}@${aws_db_instance.fleetlm.address}/${var.db_name}"
  sensitive   = true
}

output "instance_ips" {
  description = "Public IP addresses of EC2 instances"
  value       = aws_instance.fleetlm[*].public_ip
}

output "instance_private_ips" {
  description = "Private IP addresses of EC2 instances"
  value       = aws_instance.fleetlm[*].private_ip
}

output "cluster_nodes" {
  description = "Cluster nodes string for CLUSTER_NODES env var"
  value       = join(",", [for ip in aws_instance.fleetlm[*].private_ip : "fleetlm@${ip}"])
}

output "ssh_commands" {
  description = "SSH commands to connect to instances"
  value       = [for idx, ip in aws_instance.fleetlm[*].public_ip : "ssh ec2-user@${ip}"]
}

output "echo_agent_url" {
  description = "Echo agent webhook URL (API Gateway REST API with mock integration)"
  value       = "${aws_api_gateway_stage.echo_agent.invoke_url}/webhook"
}

output "echo_agent_health_url" {
  description = "Echo agent health check URL"
  value       = "${aws_api_gateway_stage.echo_agent.invoke_url}/health"
}

output "benchmark_client_ip" {
  description = "Public IP of benchmark client instance"
  value       = aws_instance.benchmark_client.public_ip
}

output "benchmark_client_private_ip" {
  description = "Private IP of benchmark client instance"
  value       = aws_instance.benchmark_client.private_ip
}

output "benchmark_client_ssh" {
  description = "SSH command for benchmark client"
  value       = "ssh ec2-user@${aws_instance.benchmark_client.public_ip}"
}
