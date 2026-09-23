# SETUP — prerequisites

Good news: **the server certificate is created automatically** by the module
(a self-signed cert via the `tls` provider, imported to ACM — no local private
key, no manual openssl step). You only need to handle **auth setup**.

## Networking prerequisites

- A VPC with a **NAT gateway** and a **private subnet** whose route table sends
  `0.0.0.0/0` through that NAT. Client egress uses the NAT's Elastic IP as the
  fixed IP. (Works with a RAM-shared VPC; the NAT may live in another account.)
- `client_cidr_block` must not overlap the VPC CIDR or peered ranges.

## Auth setup

### Federated (recommended) — IAM Identity Center SAML

See `FEDERATED.md`. You create three IAM Identity Center custom SAML apps
(client, portal, Cognito), download their metadata XML, and pass the file paths
to the module. These metadata files are safe to commit (public IdP metadata).

### Certificate auth (alternative)

If you set `auth_mode = "certificate"`, you must supply a client CA chain in ACM
via `root_certificate_chain_arn` (client certs need the `clientAuth` EKU, which
public ACM no longer issues — so this path requires an imported/private-CA cert).
Federated auth avoids per-user certs entirely and is recommended.

## Server certificate override (optional)

By default the module generates the server cert. To bring your own, set
`server_certificate_arn` to an ACM cert (public DNS-validated ACM certs are
accepted for the server cert; only the client CA needs `clientAuth`).

## Cost

- Idle: **$0** (endpoint exists, no subnet association).
- In use: ~**$0.10/hr** per association + ~**$0.05/hr** per connected user.
