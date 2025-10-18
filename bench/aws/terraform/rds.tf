resource "aws_db_subnet_group" "fleetlm" {
  name       = "fleetlm-bench-subnet-group"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Name = "fleetlm-bench-subnet-group"
  }
}

resource "aws_db_instance" "fleetlm" {
  identifier     = "fleetlm-bench"
  engine         = "postgres"
  engine_version = "15.8"
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"

  db_subnet_group_name   = aws_db_subnet_group.fleetlm.name
  vpc_security_group_ids = [aws_security_group.fleetlm_rds.id]
  publicly_accessible    = true

  # Disable backups and maintenance for ephemeral benchmark DB
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  # Disable SSL for benchmark (no cert verification issues)
  parameter_group_name = aws_db_parameter_group.fleetlm.name

  tags = {
    Name = "fleetlm-bench"
  }
}

resource "aws_db_parameter_group" "fleetlm" {
  name   = "fleetlm-bench-no-ssl"
  family = "postgres15"

  parameter {
    name  = "rds.force_ssl"
    value = "0"
  }

  tags = {
    Name = "fleetlm-bench-no-ssl"
  }
}
