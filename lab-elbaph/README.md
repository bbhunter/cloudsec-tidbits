# .: IaC Lab — ELBaph demo stack :.

**Brief lab description:** Terraform deploys two internet-facing Application Load Balancers, CloudFront in front of the public ALB, and two EC2 instances running a small Go web app. The stack models insecure ALB patterns you can explore with [ELBaph](https://github.com/doyensec/elbaph) or manually.

<img width="800" alt="Image" src="https://github.com/user-attachments/assets/e2bc2b2e-9157-45f5-8318-113b85e267fc" />

### Requirements

- The [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- An [AWS account](https://aws.amazon.com/free) and credentials that can create the resources in this stack
- The [Terraform CLI](https://developer.hashicorp.com/terraform/install) configured for AWS

### Deployment

```bash
git clone https://github.com/doyensec/cloudsec-tidbits.git
cd cloudsec-tidbits/lab-elbaph/terraform/
bash deploy-elbaph.sh
```

To tear down the stack: `bash deploy-elbaph.sh destroy` (from the same `terraform/` directory).

After apply, use `terraform output` for CloudFront URL, ALB DNS names, and instance IPs. See `terraform/README.md` for troubleshooting (502s, userdata logs, target health).

### Layout

- `app/` — Go web app and static assets (also runnable locally; see `app/README.md`).
- `terraform/` — VPC, ALBs, CloudFront, IAM, ACM (self-signed for the ALB listener), EC2 userdata.

### Lab goal (high level)

- See CloudFront geo restriction behavior and how the origin ALB may still be reachable directly.
- Work through application-level issues and instance metadata exposure as designed in the scenario.
- Compare routing on the dedicated ops ALB versus paths on the main public ALB.

Optional variables (set via `terraform.tfvars` or `-var`): `region`, `name_prefix`, `office_cidr` (source IP allowed on the ops ALB listener rule), `allowed_country_codes` (CloudFront geo whitelist), `instance_type`.
