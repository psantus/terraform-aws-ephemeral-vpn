# CLIENT — how users connect

Users need the free **AWS VPN Client**:
https://aws.amazon.com/vpn/client-vpn-download/ (macOS / Windows / Linux).
No AWS CLI or IAM credentials required — login is via your identity provider
(IAM Identity Center) in the browser.

## 1. Turn the VPN on

Open the web app (the module's `web_url` output), sign in with your company
account, and click **Start VPN**. It associates the target subnet and adds the
internet route; the page polls until it shows **VPN active** (with the egress IP)
and a link to the self-service portal. First start takes a few minutes.

## 2. Get the connection profile

- **Federated auth (recommended):** click **Open self-service portal** on the web
  app (or browse the `self_service_portal_url` output). Sign in with your IdP and
  download the AWS VPN Client and your `.ovpn` profile. No certificates to manage.
- **Certificate auth:** an admin exports the profile with
  `aws ec2 export-client-vpn-client-configuration` and distributes it, plus a
  client certificate/key issued from the configured CA.

Import the profile in the AWS VPN Client:
**File → Manage Profiles → Add Profile →** select the `.ovpn` → Add.

## 3. Connect

Select the profile → **Connect**. For federated auth a browser window opens for
your IdP login (+ MFA); approve and you're connected.

## 4. Verify the egress IP

While connected:

```bash
curl https://checkip.amazonaws.com
```

This should return the NAT gateway's Elastic IP — the fixed egress IP the whole
solution provides. (Note: the tunnel is IPv4-only; use `curl -4` if your client
defaults to IPv6.)

## 5. When done

Just disconnect. The endpoint auto-disassociates after an idle hour (billing
stops). To stop it immediately, click **Stop** on the web app.
