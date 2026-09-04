# AWS Web Host Loss pre-apply cost estimate

- Estimate date: 2026-09-04
- Region: Asia Pacific (Seoul), `ap-northeast-2`
- Source: AWS Price List API, before Free Tier or credits
- Scope: `nat_mode=none`, ALB, ASG desired 2, two 8GiB gp3 root volumes

## Public unit prices observed

| Item | Unit price |
|---|---:|
| EC2 Linux `t3.micro` | $0.013 / instance-hour |
| gp3 storage | $0.0912 / GB-month |
| Application Load Balancer | $0.0225 / ALB-hour |
| Application LCU | $0.008 / LCU-hour |
| In-use public IPv4 | $0.005 / address-hour |

Pricing references:

- <https://aws.amazon.com/ec2/pricing/on-demand/>
- <https://aws.amazon.com/ebs/pricing/>
- <https://aws.amazon.com/elasticloadbalancing/pricing/>
- <https://aws.amazon.com/vpc/pricing/>

## Incremental experiment estimate

The ALB uses two enabled AZs and is estimated as two in-use public IPv4 addresses. ASG instances have no public IPv4 addresses. EBS hourly conversion uses 730 hours/month.

The continuous probe opens about four requests/connections per second. New-connection dimension alone is approximately 0.16 LCU; actual LCU is the maximum of all LCU dimensions. The table therefore shows a 0.16–1.0 LCU range rather than assuming zero.

| Duration | EC2 2x | EBS 16GiB | ALB fixed | LCU range | Public IPv4 2x | Subtotal before data transfer |
|---|---:|---:|---:|---:|---:|---:|
| 1h | $0.0260 | $0.0020 | $0.0225 | $0.0013–0.0080 | $0.0100 | **$0.0618–0.0685** |
| 2h | $0.0520 | $0.0040 | $0.0450 | $0.0026–0.0160 | $0.0200 | **$0.1236–0.1370** |
| 4h | $0.1040 | $0.0080 | $0.0900 | $0.0051–0.0320 | $0.0400 | **$0.2471–0.2740** |

Data transfer is usage-based and excluded from the subtotal because account-wide free allocation/credits and actual bytes are unknown. The small JSON probe should use little data, but it is not assumed to be free.

VPC, subnets, route tables, internet gateway attachment, security groups, target group, launch template, and ASG have no separate hourly line item in this estimate. NAT resources are not planned.

## Entitlement uncertainty

The EC2 catalog and selected Amazon Linux 2023 AMI report `FreeTierEligible=true`. This does not prove that the authenticated account still has instance-hour, EBS, ELB, public IPv4, data-transfer, or promotional credit entitlement.

The account creation date matters. Accounts created before 2025-07-15 remain on the legacy Free Tier rules; newer accounts use the credit-based program. Because the inspected credentials do not expose a trustworthy creation date or remaining credit balance, `t3.micro` is selected as the smallest x86 option that is catalog-eligible under both rule sets. The x86 image also keeps this no-download bootstrap simpler than adding an architecture variant solely for the experiment.

The post-Free-Tier/credit result is therefore **unknown**, with a theoretical lower bound of $0 only if sufficient applicable entitlement or credits are independently confirmed in the personal account's Billing console. Account-specific inventory, usage, and credit details are intentionally not recorded in this public repository.

Free Tier program references:

- <https://aws.amazon.com/blogs/aws/aws-free-tier-update-new-customers-can-get-started-and-explore-aws-with-up-to-200-in-credits/>
- <https://docs.aws.amazon.com/cli/latest/reference/freetier/get-free-tier-usage.html>
