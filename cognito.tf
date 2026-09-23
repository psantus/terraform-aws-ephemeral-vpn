# ---------------------------------------------------------------------------
# Cognito user pool federated to IAM Identity Center (SAML), fronting the web
# UI + API. Replaces the shared-secret model with real login (MFA via IDC).
# ---------------------------------------------------------------------------

variable "cognito_domain_prefix" {
  description = "Cognito Hosted UI domain prefix (must be globally unique in the region)."
  type        = string
  default     = "ephemeral-vpn"
}

variable "cognito_callback_urls" {
  description = "Allowed OAuth callback URLs (the SPA). CloudFront URL is added automatically."
  type        = list(string)
  default     = []
}

locals {
  create_cognito_idp = var.cognito_saml_metadata_file != ""
  web_origin         = local.custom_domain_enabled ? "https://${local.custom_fqdn}" : "https://${aws_cloudfront_distribution.web.domain_name}"
  callback_urls      = concat([local.web_origin, "${local.web_origin}/"], var.cognito_callback_urls)
}

resource "aws_cognito_user_pool" "vpn" {
  name = "${local.name}-users"

  # No self sign-up; users come from IDC federation.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  tags = { Name = "${local.name}-users" }
}

# SAML identity provider federated to IAM Identity Center.
resource "aws_cognito_identity_provider" "idc" {
  count         = local.create_cognito_idp ? 1 : 0
  user_pool_id  = aws_cognito_user_pool.vpn.id
  provider_name = "IDC"
  provider_type = "SAML"

  provider_details = {
    MetadataFile = file(var.cognito_saml_metadata_file)
    IDPSignout   = "false"
  }

  attribute_mapping = {
    email = "email"
  }
}

resource "aws_cognito_user_pool_domain" "vpn" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.vpn.id
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.name}-web"
  user_pool_id = aws_cognito_user_pool.vpn.id

  generate_secret = false # public SPA client (PKCE)

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  supported_identity_providers = local.create_cognito_idp ? ["IDC"] : ["COGNITO"]

  callback_urls = local.callback_urls
  logout_urls   = local.callback_urls

  # PKCE public client; short access token.
  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 1
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  depends_on = [aws_cognito_identity_provider.idc]
}

output "cognito_hosted_ui_domain" {
  value = "https://${var.cognito_domain_prefix}.auth.${var.region}.amazoncognito.com"
}

output "cognito_saml_acs_url" {
  description = "ACS URL to configure in the IDC SAML app for Cognito."
  value       = "https://${var.cognito_domain_prefix}.auth.${var.region}.amazoncognito.com/saml2/idpresponse"
}

output "cognito_saml_entity_id" {
  description = "SP entity ID (audience) to configure in the IDC SAML app for Cognito."
  value       = "urn:amazon:cognito:sp:${aws_cognito_user_pool.vpn.id}"
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.vpn.id
}

output "cognito_web_client_id" {
  value = aws_cognito_user_pool_client.web.id
}
