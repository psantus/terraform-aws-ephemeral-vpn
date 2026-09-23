"""
Ephemeral AWS Client VPN toggle + idle auto-disassociate.

Two entrypoints in one function:

1. handler(event, context) - invoked via API Gateway HTTP API (Cognito JWT
   authorizer). Actions (query string ?action= or JSON body):
     status -> current state (associated only when subnet + 0.0.0.0/0 route ready)
     on     -> associate target subnet + ensure default internet route
     off    -> disassociate all target subnets
   Auth: API Gateway validates the Cognito JWT before invoking; the handler
   trusts the authorizer context (no shared secret).

2. idle_check(event, context) - EventBridge (hourly). Disassociates the target
   network(s) only if there were zero connections in the last full hour AND the
   association is older than an hour.

Environment:
  CLIENT_VPN_ENDPOINT_ID  required
  TARGET_SUBNET_ID        required (subnet to associate on "on")
  VPN_ENDPOINT_URL        optional (endpoint DNS, informational)
  PORTAL_URL              optional (self-service portal URL, federated auth)
  IDLE_TIMEOUT_MINUTES    optional (default 30)
"""

import json
import os
from datetime import datetime, timedelta, timezone

import boto3

ec2 = boto3.client("ec2")
cloudwatch = boto3.client("cloudwatch")
ssm = boto3.client("ssm")

ENDPOINT_ID = os.environ["CLIENT_VPN_ENDPOINT_ID"]
TARGET_SUBNET_ID = os.environ["TARGET_SUBNET_ID"]
IDLE_TIMEOUT_MINUTES = int(os.environ.get("IDLE_TIMEOUT_MINUTES", "30"))
# Grace period after association during which we never auto-disassociate,
# giving users time to actually connect before the first idle check.
GRACE_MINUTES = int(os.environ.get("GRACE_MINUTES", "15"))
ASSOC_TS_PARAM = os.environ.get("ASSOC_TS_PARAM", f"/ephemeral-vpn/{ENDPOINT_ID}/last-associated-at")
# Client VPN endpoint DNS shown to users when the VPN is active.
VPN_ENDPOINT_URL = os.environ.get("VPN_ENDPOINT_URL", "")
# Self-service portal URL (federated auth only) — the user-facing link.
PORTAL_URL = os.environ.get("PORTAL_URL", "")


def _egress_ip():
    """Discover the fixed egress IP. The Lambda runs in the same subnet as the
    VPN target, so its outbound traffic exits via the same NAT gateway — hitting
    an echo service returns exactly the IP VPN clients get. No config needed."""
    try:
        import urllib.request
        with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=3) as r:
            return r.read().decode().strip()
    except Exception:
        return ""


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _list_associations():
    """Return the list of target-network associations for the endpoint."""
    paginator = ec2.get_paginator("describe_client_vpn_target_networks")
    out = []
    for page in paginator.paginate(ClientVpnEndpointId=ENDPOINT_ID):
        out.extend(page.get("ClientVpnTargetNetworks", []))
    return out


def _active_associations(assocs):
    return [
        a
        for a in assocs
        if a.get("Status", {}).get("Code") in ("associating", "associated")
    ]


def _status():
    assocs = _list_associations()
    codes = [a.get("Status", {}).get("Code") for a in assocs]
    subnet_associated = "associated" in codes
    is_associating = (not subnet_associated) and ("associating" in codes)

    # The VPN is only truly usable when the subnet is associated AND the
    # 0.0.0.0/0 route is active. If associated but no route yet, create it.
    route_status = None
    if subnet_associated:
        route_status = _default_route_status()
        if route_status is None:
            route_status = _ensure_default_route()

    is_ready = subnet_associated and route_status == "active"

    if is_ready:
        overall = "associated"
    elif subnet_associated or is_associating:
        overall = "associating"  # associating OR associated-but-route-not-up
    elif "disassociating" in codes:
        overall = "disassociating"
    else:
        overall = "off"

    return {
        "endpoint": ENDPOINT_ID,
        # True ONLY when fully usable (subnet associated AND route active).
        "associated": is_ready,
        "associating": overall == "associating",
        "state": overall,
        "route_status": route_status,
        "ready": is_ready,
        "vpn_url": VPN_ENDPOINT_URL if is_ready else "",
        "portal_url": PORTAL_URL if is_ready else "",
        "egress_ip": _egress_ip() if is_ready else "",
        "associations": [
            {
                "association_id": a.get("AssociationId"),
                "subnet": a.get("TargetNetworkId"),
                "state": a.get("Status", {}).get("Code"),
            }
            for a in assocs
        ],
    }


def _ensure_default_route():
    """Ensure a 0.0.0.0/0 route exists on the CLIENT VPN ENDPOINT (not a VPC
    route table) so client traffic can egress to the internet via the NAT.
    Returns the route status: 'active' | 'creating' | 'deferred'."""
    try:
        ec2.create_client_vpn_route(
            ClientVpnEndpointId=ENDPOINT_ID,
            DestinationCidrBlock="0.0.0.0/0",
            TargetVpcSubnetId=TARGET_SUBNET_ID,
            Description="default internet egress via NAT",
        )
    except ec2.exceptions.ClientError as e:  # type: ignore[attr-defined]
        if "InvalidClientVpnDuplicateRoute" not in str(e):
            # subnet not fully associated yet, etc.
            return "deferred"
    return _default_route_status()


def _default_route_status():
    """Return the status of the 0.0.0.0/0 endpoint route, or None if absent."""
    try:
        r = ec2.describe_client_vpn_routes(
            ClientVpnEndpointId=ENDPOINT_ID,
            Filters=[{"Name": "destination-cidr", "Values": ["0.0.0.0/0"]}],
        )
        routes = r.get("Routes", [])
        if not routes:
            return None
        return routes[0].get("Status", {}).get("Code")
    except Exception:
        return None


def _associate():
    """Idempotent 'turn on'. VPN is only 'active' when the subnet is associated
    AND the default internet route is active.
      - route active           -> 'VPN active' (+ portal url)
      - associated, route not up-> 'VPN starting'
      - associating             -> 'VPN starting'
      - not associated          -> begin association -> 'VPN starting'
    """
    active = _active_associations(_list_associations())
    if active:
        state = active[0].get("Status", {}).get("Code")
        if state == "associated":
            route_status = _ensure_default_route()
            if route_status == "active":
                return {
                    "message": "VPN active",
                    "state": "associated",
                    "route_status": "active",
                    "ready": True,
                    "vpn_url": VPN_ENDPOINT_URL,
                    "portal_url": PORTAL_URL,
                    "egress_ip": _egress_ip(),
                    "endpoint": ENDPOINT_ID,
                }
            # associated but route still coming up
            return {
                "message": "VPN starting",
                "state": "associated",
                "route_status": route_status or "creating",
                "ready": False,
                "endpoint": ENDPOINT_ID,
            }
        # associating (or any non-associated active state)
        return {"message": "VPN starting", "state": state, "route_status": None, "ready": False, "endpoint": ENDPOINT_ID}

    r = ec2.associate_client_vpn_target_network(
        ClientVpnEndpointId=ENDPOINT_ID,
        SubnetId=TARGET_SUBNET_ID,
    )
    # Record association time so idle_check honors the "associated within the
    # last hour" rule.
    try:
        ssm.put_parameter(
            Name=ASSOC_TS_PARAM,
            Value=datetime.now(timezone.utc).isoformat(),
            Type="String",
            Overwrite=True,
        )
    except Exception:
        pass
    return {
        "message": "VPN starting",
        "state": r.get("Status", {}).get("Code"),
        "endpoint": ENDPOINT_ID,
    }


def _disassociate():
    active = _active_associations(_list_associations())
    if not active:
        return {"message": "already disassociated"}
    results = []
    for a in active:
        r = ec2.disassociate_client_vpn_target_network(
            ClientVpnEndpointId=ENDPOINT_ID,
            AssociationId=a["AssociationId"],
        )
        results.append(
            {"association_id": a["AssociationId"], "state": r.get("Status", {}).get("Code")}
        )
    return {"message": "disassociating", "results": results}


def _authorized(event):
    """Requests arrive via API Gateway HTTP API with a Cognito JWT authorizer.
    API Gateway validates the JWT before invoking us, and populates
    requestContext.authorizer.jwt. We simply require that context to be present.
    """
    authz = (
        event.get("requestContext", {})
        .get("authorizer", {})
    )
    return bool(authz.get("jwt") or authz.get("claims"))


def _caller_email(event):
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    return claims.get("email") or claims.get("cognito:username") or "unknown"


# --------------------------------------------------------------------------- #
# HTTP entrypoint (API Gateway HTTP API or Lambda Function URL)
# --------------------------------------------------------------------------- #
def handler(event, context):
    if not _authorized(event):
        return _resp(403, {"error": "forbidden"})

    method = (
        event.get("requestContext", {})
        .get("http", {})
        .get("method", "GET")
        .upper()
    )

    qs = event.get("queryStringParameters") or {}
    if method == "GET":
        action = qs.get("action", "on")
    else:
        raw = event.get("body") or "{}"
        try:
            action = (json.loads(raw) or {}).get("action") or qs.get("action", "status")
        except json.JSONDecodeError:
            return _resp(400, {"error": "invalid JSON body"})

    try:
        if action == "status":
            return _resp(200, _status())
        if action == "on":
            return _resp(200, _associate())
        if action == "off":
            return _resp(200, _disassociate())
        return _resp(400, {"error": f"unknown action: {action!r}", "allowed": ["status", "on", "off"]})
    except ec2.exceptions.ClientError as e:  # type: ignore[attr-defined]
        return _resp(500, {"error": str(e)})


# --------------------------------------------------------------------------- #
# EventBridge idle-check entrypoint
# --------------------------------------------------------------------------- #
def idle_check(event, context):
    """Hourly idle check.

    Disassociate the endpoint ONLY IF, over the last full hour:
      - there were zero active connections, AND
      - the association itself was made more than an hour ago
        (i.e. it wasn't associated during this same hour).
    Otherwise keep it associated.
    """
    active = _active_associations(_list_associations())
    if not active:
        return {"idle": True, "action": "none (not associated)"}

    now = datetime.now(timezone.utc)
    window = timedelta(hours=1)

    # 1) Was the association made within the last hour? If so, keep it.
    try:
        p = ssm.get_parameter(Name=ASSOC_TS_PARAM)
        associated_at = datetime.fromisoformat(p["Parameter"]["Value"])
        age = now - associated_at
        if age < window:
            return {
                "idle": False,
                "action": "associated within the last hour",
                "age_minutes": round(age.total_seconds() / 60.0, 1),
            }
    except ssm.exceptions.ParameterNotFound:
        # No timestamp recorded; fall through to connection check.
        pass
    except Exception:
        pass

    # 2) Any connections in the last full hour?
    metrics = cloudwatch.get_metric_statistics(
        Namespace="AWS/ClientVPN",
        MetricName="ActiveConnectionsCount",
        Dimensions=[{"Name": "Endpoint", "Value": ENDPOINT_ID}],
        StartTime=now - window,
        EndTime=now,
        Period=3600,
        Statistics=["Maximum"],
    )
    datapoints = metrics.get("Datapoints", [])
    max_conns = max((d["Maximum"] for d in datapoints), default=0.0)

    if max_conns > 0:
        return {"idle": False, "max_connections": max_conns, "action": "kept associated"}

    result = _disassociate()
    return {"idle": True, "max_connections": 0, "action": "disassociated", "detail": result}
