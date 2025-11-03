output "db_endpoints" {
  value = {
    db1 = aws_db_instance.db1.address
    db2 = aws_db_instance.db2.address
    db3 = aws_db_instance.db3.address
  }
}
output "lambda_invoke_arn" { value = aws_lambda_function.consistency.arn }
output "event_rule_name"   { value = aws_cloudwatch_event_rule.detect_inconsistency.name }
