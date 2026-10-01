variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Name prefix for all resources (rename to reuse this stack)."
  type        = string
  default     = "ephemeral-vpn"
}

variable "app_title" {
  description = "Display name shown in the web UI (title + heading)."
  type        = string
  default     = "Ephemeral VPN"
}

variable "dns_hosted_zone_name" {
  description = "Optional Route53 public hosted zone name for a custom web-app domain (e.g. example.com). Empty = use the CloudFront default domain."
  type        = string
  default     = ""
}

variable "dns_name" {
  description = "Optional subdomain label for the web app (e.g. 'vpn' -> vpn.<dns_hosted_zone_name>). Requires dns_hosted_zone_name."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "Shared VPC id (owned by the network/sharer account)"
  type        = string
}

variable "target_subnet_id" {
  description = "Private subnet to associate (egresses via sharer NAT = fixed IP)"
  type        = string
}

variable "client_cidr_block" {
  description = "CIDR from which VPN client IPs are allocated. Must NOT overlap the VPC CIDR or peered ranges."
  type        = string
  default     = "10.100.0.0/22"
}

variable "dns_servers" {
  description = "DNS servers pushed to VPN clients. Public IPv4 resolvers by default to avoid the shared VPC's DNS64/NAT64 synthetic IPv6 answers (which break the IPv4-only tunnel). Egress still goes via the NAT (split_tunnel=false)."
  type        = list(string)
  default     = ["8.8.8.8", "1.1.1.1"]
}

variable "vpn_access_cidr" {
  description = "Destination CIDR clients are authorized to reach. 0.0.0.0/0 = full internet egress via NAT (fixed IP use case)."
  type        = string
  default     = "0.0.0.0/0"
}

variable "auth_mode" {
  description = "Client VPN user auth: 'certificate' (mutual TLS client certs) or 'federated' (IAM Identity Center SAML)."
  type        = string
  default     = "certificate"
  validation {
    condition     = contains(["certificate", "federated"], var.auth_mode)
    error_message = "auth_mode must be 'certificate' or 'federated'."
  }
}

variable "saml_provider_arn" {
  description = "IAM SAML provider ARN for IAM Identity Center federation (created from IDC metadata; see SETUP.md). Required only when auth_mode = 'federated'."
  type        = string
  default     = ""
}

variable "root_certificate_chain_arn" {
  description = "ACM ARN of the client-certificate CA chain (mutual TLS). Required only when auth_mode = 'certificate'. Often the same ARN as server_certificate_arn when one CA signs both."
  type        = string
  default     = ""
}

variable "self_service_saml_provider_arn" {
  description = "IAM SAML provider ARN for the self-service portal (separate IDC app with the portal ACS). Auto-created from portal_saml_metadata_file if provided."
  type        = string
  default     = ""
}

variable "client_saml_metadata_file" {
  description = "Path to the IAM Identity Center SAML metadata XML for the VPN CLIENT app (ACS http://127.0.0.1:35001). If set, the module creates the IAM SAML provider from it. Otherwise set saml_provider_arn."
  type        = string
  default     = ""
}

variable "portal_saml_metadata_file" {
  description = "Path to the IDC SAML metadata XML for the self-service PORTAL app (ACS .../api/auth/sso/saml). Optional; enables the portal."
  type        = string
  default     = ""
}

variable "cognito_saml_metadata_file" {
  description = "Path to the IDC SAML metadata XML for the COGNITO app (ACS .../saml2/idpresponse). If set, Cognito federates to IDC; otherwise Cognito uses its own directory."
  type        = string
  default     = ""
}

variable "server_certificate_arn" {
  description = "ACM ARN of the Client VPN server certificate. Leave empty (default) to have Terraform auto-generate a self-signed cert and import it to ACM — no local private key; the key lives only in Terraform state."
  type        = string
  default     = ""
}

variable "server_cert_domain" {
  description = "CN/SAN for the auto-generated self-signed server cert (default: server.<project_name>.vpn.internal). It only names the server cert; not user-facing."
  type        = string
  default     = ""
}

variable "expected_assoc_sec" {
  description = "Expected Client VPN association time (seconds) for the web UI progress estimate. Measured deterministically at ~369s (associate API call -> state=associated) on 2026-09-18; association time varies (~200-370s), so this is an estimate. The bar snaps to 100% only when truly associated."
  type        = number
  default     = 360
}


variable "tags" {
  type = map(string)
  default = {
    ManagedBy = "terraform"
  }
}
