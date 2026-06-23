terraform {
  backend "s3" {
    # Run scripts/bootstrap-state.sh first to create the bucket.
    bucket         = "petclinic-terraform-state-092443461861"
    key            = "petclinic/dev/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "petclinic-terraform-locks"
    encrypt        = true
  }
}
