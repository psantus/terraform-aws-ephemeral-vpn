# ---------------------------------------------------------------------------
# API Gateway HTTP API in front of the toggle Lambda, protected by a Cognito
# JWT authorizer. Replaces the shared-secret Function URL.
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "toggle" {
  name          = "${local.name}-toggle-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = [local.web_origin]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.toggle.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.vpn.id}"
  }
}

resource "aws_apigatewayv2_integration" "toggle" {
  api_id                 = aws_apigatewayv2_api.toggle.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.toggle.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "toggle_get" {
  api_id             = aws_apigatewayv2_api.toggle.id
  route_key          = "GET /vpn"
  target             = "integrations/${aws_apigatewayv2_integration.toggle.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "toggle_post" {
  api_id             = aws_apigatewayv2_api.toggle.id
  route_key          = "POST /vpn"
  target             = "integrations/${aws_apigatewayv2_integration.toggle.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.toggle.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.toggle.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.toggle.execution_arn}/*/*"
}

output "api_url" {
  description = "Secure API endpoint (Cognito JWT protected). Call GET/POST {api_url}/vpn."
  value       = "${aws_apigatewayv2_api.toggle.api_endpoint}/vpn"
}
