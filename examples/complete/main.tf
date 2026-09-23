terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 6.0" }
    null = { source = "hashicorp/null", version = "~> 3.0" }
  }
}

provider "aws" {
  region = "eu-west-3"
  default_tags {
    tags = { Project = "ephemeral-vpn" }
  }
}

module "vpn" {
  source = "../.."

  region       = "eu-west-3"
  project_name = "acme-vpn"
  app_title    = "Acme VPN"

  vpc_id           = "vpc-xxxxxxxx"
  target_subnet_id = "subnet-xxxxxxxx" # private subnet routing 0.0.0.0/0 via NAT

  auth_mode              = "federated"
  server_certificate_arn = "arn:aws:acm:eu-west-3:123456789012:certificate/xxxx"

  # IAM Identity Center SAML metadata (see FEDERATED.md)
  client_saml_metadata_file  = "${path.module}/idc/client.xml"
  portal_saml_metadata_file  = "${path.module}/idc/portal.xml"
  cognito_saml_metadata_file = "${path.module}/idc/cognito.xml"

  cognito_domain_prefix = "acme-vpn"

  # Optional custom domain for the login web app
  dns_hosted_zone_name = "example.com"
  dns_name             = "vpn"
}

output "web_url" { value = module.vpn.web_url }
output "portal" { value = module.vpn.self_service_portal_url }
