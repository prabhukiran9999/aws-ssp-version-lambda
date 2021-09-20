terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.48.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.2.0"
    }
  }

  required_version = "~> 1.0"
}

provider "aws" {
  region = var.aws_region
}

resource "random_pet" "lambda_bucket_name" {
  prefix = "greeting-lambda"
  length = 2
}

resource "aws_s3_bucket" "lambda_bucket" {
  bucket = random_pet.lambda_bucket_name.id
  acl           = "private"
  force_destroy = true
}



resource "aws_s3_bucket_object" "lambda_greetings_server" {
  bucket = aws_s3_bucket.lambda_bucket.id
  key    = "greetings-server.zip"
  source = "./lambda/server"
  
}


resource "aws_dynamodb_table" "ssp-greetings" {
  name             = "ssp-greetings"
  hash_key         = "pid"
  range_key = "id"
  
  billing_mode   = "PAY_PER_REQUEST"
  read_capacity  = 5
  write_capacity = 5
  attribute {
    name = "pid"
    type = "S"
  }
  attribute {
    name = "id"
    type = "S"
  }
}



# resource "aws_iam_role_policy_attachment" "lambda_task_execution_role" {
#   role       = aws_iam_role.lambda_exec.name
#   policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
# }


resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda_policy"
  role = aws_iam_role.lambda_exec.id
  policy = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
          "Effect": "Allow",
          "Action": [
              "dynamodb:BatchGet*",
              "dynamodb:DescribeStream",
              "dynamodb:DescribeTable",
              "dynamodb:Get*",
              "dynamodb:Query",
              "dynamodb:Scan",
              "dynamodb:BatchWrite*",
              "dynamodb:CreateTable",
              "dynamodb:Delete*",
              "dynamodb:Update*",
              "dynamodb:PutItem"
          ],
          "Resource": "${aws_dynamodb_table.ssp-greetings.arn}"
        },
        {
          "Effect": "Allow",
           "Action": [
                  "logs:CreateLogGroup",
                  "logs:CreateLogStream",
                  "logs:PutLogEvents",
                  "logs:DescribeLogStreams"
              ],
          "Resource": "*"
      }
    ]
  }
  EOF 
}
resource "aws_iam_role" "lambda_exec" {
  name = "serverless_lambda"
  
  assume_role_policy = file("assume_role_policy.json")
}

resource "aws_lambda_function" "greetings_server_lambda" {
  function_name = "greetings_server_fn"

  s3_bucket = aws_s3_bucket.lambda_bucket.id
  s3_key    = aws_s3_bucket_object.lambda_greetings_server.key

  runtime = "nodejs12.x"
  handler = "./server/lambda.handler"

  source_code_hash = data.archive_file.lambda_greetings_server.output_base64sha256

  role = aws_iam_role.lambda_exec.arn
}

#resource "aws_cloudwatch_log_group" "greetings_server_logs" {
  #name = "/aws/lambda/${aws_lambda_function.greetings_server_lambda.function_name}"

  #retention_in_days = 30
#}

resource "aws_api_gateway_rest_api" "apiLambda" {
  name        = "myAPI"
}



resource "aws_api_gateway_resource" "proxy" {
   rest_api_id = aws_api_gateway_rest_api.apiLambda.id
   parent_id   = aws_api_gateway_rest_api.apiLambda.root_resource_id
   path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxyMethod" {
   rest_api_id   = aws_api_gateway_rest_api.apiLambda.id
   resource_id   = aws_api_gateway_resource.proxy.id
   http_method   = "ANY"
   authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
   rest_api_id = aws_api_gateway_rest_api.apiLambda.id
   resource_id = aws_api_gateway_method.proxyMethod.resource_id
   http_method = aws_api_gateway_method.proxyMethod.http_method

   integration_http_method = "POST"
   type                    = "AWS_PROXY"
   uri                     = aws_lambda_function.greetings_server_lambda.invoke_arn
}




resource "aws_api_gateway_method" "proxy_root" {
   rest_api_id   = aws_api_gateway_rest_api.apiLambda.id
   resource_id   = aws_api_gateway_rest_api.apiLambda.root_resource_id
   http_method   = "ANY"
   authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_root" {
   rest_api_id = aws_api_gateway_rest_api.apiLambda.id
   resource_id = aws_api_gateway_method.proxy_root.resource_id
   http_method = aws_api_gateway_method.proxy_root.http_method

   integration_http_method = "POST"
   type                    = "AWS_PROXY"
   uri                     = aws_lambda_function.greetings_server_lambda.invoke_arn
}


resource "aws_api_gateway_deployment" "apideploy" {
   depends_on = [
     aws_api_gateway_integration.lambda,
     aws_api_gateway_integration.lambda_root,
   ]

   rest_api_id = aws_api_gateway_rest_api.apiLambda.id
   stage_name  = "test"
}


resource "aws_lambda_permission" "apigw" {
   statement_id  = "AllowAPIGatewayInvoke"
   action        = "lambda:InvokeFunction"
   function_name = aws_lambda_function.greetings_server_lambda.function_name
   principal     = "apigateway.amazonaws.com"

   # The "/*/*" portion grants access from any method on any resource
   # within the API Gateway REST API.
   source_arn = "${aws_api_gateway_rest_api.apiLambda.execution_arn}/*/*"
}

