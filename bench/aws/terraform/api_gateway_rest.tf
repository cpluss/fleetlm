resource "aws_api_gateway_rest_api" "echo_agent" {
  name        = "fleetlm-echo-agent"
  description = "Static echo agent for FleetLM benchmarks - returns AI SDK JSONL"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Name = "fleetlm-echo-agent-bench"
  }
}

# /webhook resource
resource "aws_api_gateway_resource" "webhook" {
  rest_api_id = aws_api_gateway_rest_api.echo_agent.id
  parent_id   = aws_api_gateway_rest_api.echo_agent.root_resource_id
  path_part   = "webhook"
}

# POST /webhook method
resource "aws_api_gateway_method" "webhook_post" {
  rest_api_id   = aws_api_gateway_rest_api.echo_agent.id
  resource_id   = aws_api_gateway_resource.webhook.id
  http_method   = "POST"
  authorization = "NONE"
}

# Mock integration for POST /webhook
resource "aws_api_gateway_integration" "webhook_post" {
  rest_api_id = aws_api_gateway_rest_api.echo_agent.id
  resource_id = aws_api_gateway_resource.webhook.id
  http_method = aws_api_gateway_method.webhook_post.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

# Integration response for POST /webhook
resource "aws_api_gateway_integration_response" "webhook_post" {
  rest_api_id = aws_api_gateway_rest_api.echo_agent.id
  resource_id = aws_api_gateway_resource.webhook.id
  http_method = aws_api_gateway_method.webhook_post.http_method
  status_code = aws_api_gateway_method_response.webhook_post_200.status_code

  response_templates = {
    "application/json" = <<-EOT
{"type":"text-start","id":"part_1"}
{"type":"text-delta","id":"part_1","delta":"ack"}
{"type":"text-end","id":"part_1"}
{"type":"finish"}
EOT
  }

  depends_on = [aws_api_gateway_integration.webhook_post]
}

# Method response for POST /webhook
resource "aws_api_gateway_method_response" "webhook_post_200" {
  rest_api_id = aws_api_gateway_rest_api.echo_agent.id
  resource_id = aws_api_gateway_resource.webhook.id
  http_method = aws_api_gateway_method.webhook_post.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Content-Type" = true
  }
}

# /health resource
resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.echo_agent.id
  parent_id   = aws_api_gateway_rest_api.echo_agent.root_resource_id
  path_part   = "health"
}

# GET /health method
resource "aws_api_gateway_method" "health_get" {
  rest_api_id   = aws_api_gateway_rest_api.echo_agent.id
  resource_id   = aws_api_gateway_resource.health.id
  http_method   = "GET"
  authorization = "NONE"
}

# Mock integration for GET /health
resource "aws_api_gateway_integration" "health_get" {
  rest_api_id = aws_api_gateway_rest_api.echo_agent.id
  resource_id = aws_api_gateway_resource.health.id
  http_method = aws_api_gateway_method.health_get.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

# Integration response for GET /health
resource "aws_api_gateway_integration_response" "health_get" {
  rest_api_id = aws_api_gateway_rest_api.echo_agent.id
  resource_id = aws_api_gateway_resource.health.id
  http_method = aws_api_gateway_method.health_get.http_method
  status_code = aws_api_gateway_method_response.health_get_200.status_code

  response_templates = {
    "application/json" = "{\"status\":\"ok\",\"agent\":\"fleetlm-echo-agent\"}"
  }

  depends_on = [aws_api_gateway_integration.health_get]
}

# Method response for GET /health
resource "aws_api_gateway_method_response" "health_get_200" {
  rest_api_id = aws_api_gateway_rest_api.echo_agent.id
  resource_id = aws_api_gateway_resource.health.id
  http_method = aws_api_gateway_method.health_get.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Content-Type" = true
  }
}

# Deployment
resource "aws_api_gateway_deployment" "echo_agent" {
  rest_api_id = aws_api_gateway_rest_api.echo_agent.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.webhook.id,
      aws_api_gateway_method.webhook_post.id,
      aws_api_gateway_integration.webhook_post.id,
      aws_api_gateway_resource.health.id,
      aws_api_gateway_method.health_get.id,
      aws_api_gateway_integration.health_get.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.webhook_post,
    aws_api_gateway_integration.health_get,
  ]
}

# Stage
resource "aws_api_gateway_stage" "echo_agent" {
  deployment_id = aws_api_gateway_deployment.echo_agent.id
  rest_api_id   = aws_api_gateway_rest_api.echo_agent.id
  stage_name    = "prod"

  tags = {
    Name = "fleetlm-echo-agent-bench"
  }
}
