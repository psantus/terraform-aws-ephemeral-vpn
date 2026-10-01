# ---------------------------------------------------------------------------
# Toggle Lambda (Function URL) + idle-check (EventBridge) + scoped IAM.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/build/handler.zip"
}

# --- IAM role scoped to THIS endpoint only ---
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-toggle-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "lambda" {
  # Read associations / describe (no resource-level support -> scoped by condition where possible).
  statement {
    sid = "DescribeClientVpn"
    actions = [
      "ec2:DescribeClientVpnTargetNetworks",
      "ec2:DescribeClientVpnEndpoints",
    ]
    resources = ["*"]
  }

  # Associate/disassociate. NOTE: these EC2 actions do NOT support resource-level
  # scoping on the target subnet (and the subnet is cross-account via shared VPC),
  # so they must be granted on "*". The blast radius is limited to just these two
  # Client-VPN association actions.
  statement {
    sid = "ToggleAssociation"
    actions = [
      "ec2:AssociateClientVpnTargetNetwork",
      "ec2:DisassociateClientVpnTargetNetwork",
    ]
    resources = ["*"]
  }

  # Endpoint routes (0.0.0.0/0 for internet egress). These are Client VPN
  # endpoint routes, NOT VPC route tables. Not resource-scopable, so "*".
  statement {
    sid = "EndpointRoutes"
    actions = [
      "ec2:CreateClientVpnRoute",
      "ec2:DeleteClientVpnRoute",
      "ec2:DescribeClientVpnRoutes",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadMetrics"
    actions   = ["cloudwatch:GetMetricStatistics"]
    resources = ["*"]
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.name}-toggle-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# VPC access for the toggle Lambda (in-subnet, to self-discover egress IP via
# the same NAT). Requires ENI management permissions.
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_security_group" "lambda" {
  name        = "${local.name}-toggle-lambda-sg"
  description = "Toggle Lambda in-VPC: egress only (to NAT + AWS APIs)"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-toggle-lambda-sg" }
}

# --- Toggle function (in-VPC; behind API Gateway) ---
resource "aws_lambda_function" "toggle" {
  function_name    = "${local.name}-toggle"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30

  vpc_config {
    subnet_ids         = [var.target_subnet_id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      CLIENT_VPN_ENDPOINT_ID = aws_ec2_client_vpn_endpoint.this.id
      TARGET_SUBNET_ID       = var.target_subnet_id
      VPN_ENDPOINT_URL       = aws_ec2_client_vpn_endpoint.this.dns_name
      PORTAL_URL             = var.auth_mode == "federated" ? "https://self-service.clientvpn.amazonaws.com/endpoints/${aws_ec2_client_vpn_endpoint.this.id}" : ""
    }
  }
}


# --- Idle checker (EventBridge scheduled) ---
resource "aws_lambda_function" "idle" {
  function_name    = "${local.name}-idle-check"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.idle_check"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      CLIENT_VPN_ENDPOINT_ID = aws_ec2_client_vpn_endpoint.this.id
      TARGET_SUBNET_ID       = var.target_subnet_id
    }
  }
}

resource "aws_cloudwatch_event_rule" "idle" {
  name                = "${local.name}-idle-check"
  description         = "Periodically disassociate Client VPN when idle"
  schedule_expression = "rate(15 minutes)"
}

resource "aws_cloudwatch_event_target" "idle" {
  rule = aws_cloudwatch_event_rule.idle.name
  arn  = aws_lambda_function.idle.arn
}

resource "aws_lambda_permission" "idle_events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.idle.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.idle.arn
}
