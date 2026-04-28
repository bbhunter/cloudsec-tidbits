# Terraform Notes

This folder contains the Terraform stack for the ELBaph demo lab.

It is intentionally simple:

- 1 VPC with 2 public subnets
- 1 vulnerable **web** instance (public ALB default target)
- 1 **ops** instance
- 2 internet-facing ALBs
- 1 CloudFront distribution in front of the **main public ALB**

The web instance bootstraps the Go app from the local `../app` folder via userdata (no containers).
