# Federated auth (IAM Identity Center) + self-service portal

This module supports AWS Client VPN federated auth via SAML, plus the self-service
portal, using IAM Identity Center. Because Client VPN uses **two fixed ACS URLs**
and IAM Identity Center's custom SAML app form accepts only **one** ACS URL, you
create **separate SAML apps** and register their metadata with the module.

## The three IAM Identity Center custom SAML apps

Client VPN + Cognito send fixed SAML values. Create these custom SAML 2.0 apps in
IAM Identity Center (console — Terraform can't create custom-SAML apps):

| App | ACS URL | SAML audience |
|-----|---------|---------------|
| VPN client | `http://127.0.0.1:35001` | `urn:amazon:webservices:clientvpn` |
| Self-service portal | `https://self-service.clientvpn.amazonaws.com/api/auth/sso/saml` | `urn:amazon:webservices:clientvpn` |
| Cognito | `https://<cognito_domain_prefix>.auth.<region>.amazoncognito.com/saml2/idpresponse` | `urn:amazon:cognito:sp:<user-pool-id>` |

**Attribute mappings are mandatory** (a missing/insufficient mapping causes
"Resource not found / confirm your primary email is assigned" on sign-in):

| App | Required attribute mappings |
|-----|------------------------------|
| VPN client | `Subject` = `${user:email}` (emailAddress) + `FirstName` = `${user:givenName}` + `LastName` = `${user:familyName}` |
| Self-service portal | `Subject` = `${user:email}` (emailAddress) + `FirstName` = `${user:givenName}` + `LastName` = `${user:familyName}` |
| Cognito | `Subject` = `${user:email}` (emailAddress) + attribute `email` = `${user:email}` |

- AWS Client VPN requires **at least one attribute** in the assertion beyond the
  NameID. `FirstName`/`LastName` satisfy that for the client and portal apps —
  `Subject` alone is not enough.
- The `email` attribute on the **Cognito** app is what Cognito reads for the
  user's email.

Assign your users/groups to all three apps. Download each app's IDC SAML
metadata and pass the file paths to the module:

```hcl
module "vpn" {
  # ...
  auth_mode                  = "federated"
  client_saml_metadata_file  = "${path.module}/idc/client.xml"
  portal_saml_metadata_file  = "${path.module}/idc/portal.xml"   # optional (enables portal)
  cognito_saml_metadata_file = "${path.module}/idc/cognito.xml"
}
```

The Cognito ACS URL and audience depend on the Cognito user pool ID, which only
exists after apply — but this is NOT a two-phase apply. The metadata IDC emits
(entityID, SSO URL, signing cert) does not depend on the ACS/audience, so you can
create all three apps up front and fix the Cognito ACS afterward:

## Bootstrap (one apply)

1. **Create all three IDC custom SAML apps** now:
   - **Client** and **Portal**: use the fixed ACS/audience from the table above.
   - **Cognito**: ACS URL is `https://<cognito_domain_prefix>.auth.<region>.amazoncognito.com/saml2/idpresponse`
     (the prefix is a variable you choose, so it's known up front). For the
     **audience**, put a **placeholder** (e.g. `urn:amazon:cognito:sp:PENDING`) —
     you'll correct it in step 4.
   - Set the attribute mappings (all three: `Subject = ${user:email}`; Cognito also
     `email = ${user:email}`) and assign your users.
2. **Download all three metadata XMLs** into `idc/` and point the module at them.
3. **`terraform apply`.** The whole stack builds (the VPN works immediately). Read
   the outputs `cognito_saml_acs_url` and `cognito_saml_entity_id`.
4. **Update the Cognito IDC app**: set its ACS URL and **audience** to the real
   output values. No re-apply needed — the metadata (signing cert/entityID) is
   unchanged, so the `aws_cognito_identity_provider` resource is unaffected. Only
   the IDC-side SP config changed, which is what makes the Cognito login redirect
   succeed.

After step 4, Cognito login (and the whole web-app flow) works. Before it, the
infra is fully applied but Cognito sign-in would fail the redirect — the VPN
client/portal SAML paths (which have fixed ACS/audience) work regardless.

## Notes

- A Client VPN endpoint supports two SAML providers: `saml_provider_arn` (client)
  and `self_service_saml_provider_arn` (portal). The module wires both.
- Switching IdP later = replace the metadata files and re-apply. Changing endpoint
  auth options forces endpoint replacement; disassociate any active association
  first.
- The SAML audience `urn:amazon:webservices:clientvpn` is fixed by AWS and shared
  by ALL Client VPN endpoints (not per-endpoint). Your protection is IdP-side: only
  users you assign to the app can authenticate, and the endpoint trusts only your
  IdP's metadata. Keep app assignments tight and rely on IdP MFA.
