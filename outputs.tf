output "client_vpn_endpoint_id" {
  description = "Client VPN endpoint id"
  value       = aws_ec2_client_vpn_endpoint.this.id
}

output "self_service_portal_url" {
  description = "Self-service portal URL (federated auth only). Users sign in with IDC and download their config."
  value       = var.auth_mode == "federated" ? "https://self-service.clientvpn.amazonaws.com/endpoints/${aws_ec2_client_vpn_endpoint.this.id}" : "n/a (certificate auth)"
}

output "client_vpn_dns_name" {
  description = "Endpoint DNS name (used in the .ovpn client config)"
  value       = aws_ec2_client_vpn_endpoint.this.dns_name
}

output "target_subnet_id" {
  value = var.target_subnet_id
}

output "connection_log_group" {
  value = aws_cloudwatch_log_group.vpn.name
}

output "usage_hint" {
  value = <<-EOT
    Open the web UI (web_url), sign in via Cognito/IDC, then Start/Stop the VPN.
    The API (api_url) is protected by a Cognito JWT authorizer — call it with an
    Authorization: Bearer <id_token> header. No shared secret.
  EOT
}
