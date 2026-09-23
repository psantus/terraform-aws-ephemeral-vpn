terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# --- Data sources: consume the (possibly shared) VPC/subnet ---
data "aws_vpc" "shared" {
  id = var.vpc_id
}

data "aws_subnet" "target" {
  id = var.target_subnet_id
}

locals {
  name = var.project_name
  # Client app SAML provider (main auth). From caller-provided metadata file.
  create_saml        = var.client_saml_metadata_file != ""
  effective_saml_arn = local.create_saml ? aws_iam_saml_provider.idc[0].arn : var.saml_provider_arn

  # Self-service PORTAL SAML provider (separate app, portal ACS). Optional.
  create_portal_saml   = var.portal_saml_metadata_file != ""
  effective_portal_arn = local.create_portal_saml ? aws_iam_saml_provider.portal[0].arn : var.self_service_saml_provider_arn
}

resource "aws_iam_saml_provider" "idc" {
  count                  = local.create_saml ? 1 : 0
  name                   = "${local.name}-idc"
  saml_metadata_document = file(var.client_saml_metadata_file)
}

resource "aws_iam_saml_provider" "portal" {
  count                  = local.create_portal_saml ? 1 : 0
  name                   = "${local.name}-idc-portal"
  saml_metadata_document = file(local.create_portal_saml ? var.portal_saml_metadata_file : var.client_saml_metadata_file)
}
