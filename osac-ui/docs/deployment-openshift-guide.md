# OSAC UI OpenShift deployment guide

Step-by-step guide for deploying the OSAC UI on an OpenShift cluster with a running fulfillment-service and Keycloak.

## Prerequisites

- OpenShift cluster with `oc` CLI access.
- **fulfillment-service** deployed and reachable from the cluster (the `fulfillment-internal-api` Service must exist).
- **Keycloak** deployed with an OIDC realm (e.g. `osac`).
- Podman (or Docker) for building the container image.
- A container registry you can push to (e.g. `quay.io`).

## 1. Build and push the container image

```bash
podman build -t quay.io/<your-org>/osac-ui:latest -f Containerfile .
podman login quay.io
podman push quay.io/<your-org>/osac-ui:latest
```

## 2. Configure Keycloak

### 2.1. Set the external hostname

Keycloak must advertise its **external route URL** in the OIDC discovery document; otherwise the browser is redirected to an internal `svc.cluster.local` address it cannot resolve.

For Keycloak on Quarkus (v17+), set the `KC_HOSTNAME` environment variable on the Keycloak deployment:

```bash
oc set env deployment/keycloak-service -n keycloak \
  KC_HOSTNAME=keycloak-keycloak.apps.<cluster-domain>
```

Verify by checking the `authorization_endpoint` in the discovery document:

```bash
curl -sk https://keycloak-keycloak.apps.<cluster-domain>/realms/osac/.well-known/openid-configuration | jq .authorization_endpoint
```

It must return the external route hostname, not `svc.cluster.local`.

> **Important:** after updating `KC_HOSTNAME`, the Authorino `AuthConfig` and the `fulfillment-controller` deployment must also reference the new external route URL as the trusted token issuer. See [section 2.4](#24-configure-the-fulfillment-trusted-issuer).

If Keycloak TLS certificates are managed by cert-manager, ensure the route hostname is included as a SAN in the `Certificate` resource. Otherwise the UI proxy will fail OIDC discovery with a hostname mismatch error:

```bash
oc patch certificate -n keycloak keycloak-tls --type=json \
  -p='[{"op":"add","path":"/spec/dnsNames/-","value":"keycloak-keycloak.apps.<cluster-domain>"}]'
```

After patching, restart Keycloak so it picks up the regenerated certificate:

```bash
oc rollout restart deployment/keycloak-service -n keycloak
```

### 2.2. Register the OIDC client

Create a public OIDC client in the **osac** realm (not in the master realm):

| Setting               | Value                                                          |
| --------------------- | -------------------------------------------------------------- |
| Client ID             | `osac-ui`                                                      |
| Client type           | OpenID Connect                                                 |
| Client authentication | Off (public client)                                            |
| Standard flow         | Enabled                                                        |
| Root URL              | `https://osac-ui-<namespace>.apps.<cluster-domain>`            |
| Valid redirect URIs   | `https://osac-ui-<namespace>.apps.<cluster-domain>/callback`   |
| Web origins           | `https://osac-ui-<namespace>.apps.<cluster-domain>`            |

Notice that the Keycloak admin user and password can be obtained from the KEYCLOAK_ADMIN and KEYCLOAK_ADMIN_PASSWORD variables set in the keycloak deployment

```bash
oc get deployment/keycloak-service -n keycloak -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={"="}{.value}{"\n"}{end}' | grep -E '^KEYCLOAK_ADMIN(_PASSWORD)?='
```

Via Keycloak admin API:

 > **Information:** The OIDC client configuration can also be done through the Keycloak UI.

```bash
# Obtain an admin token
TOKEN=$(curl -sk -X POST \
  "https://keycloak-keycloak.apps.<cluster-domain>/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=<admin-password>" \
  | jq -r .access_token)

# Create the client in realm osac
curl -sk -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://keycloak-keycloak.apps.<cluster-domain>/admin/realms/osac/clients" \
  -d '{
    "clientId": "osac-ui",
    "publicClient": true,
    "directAccessGrantsEnabled": false,
    "standardFlowEnabled": true,
    "rootUrl": "https://osac-ui-<namespace>.apps.<cluster-domain>",
    "redirectUris": ["https://osac-ui-<namespace>.apps.<cluster-domain>/callback"],
    "webOrigins": ["https://osac-ui-<namespace>.apps.<cluster-domain>"],
    "protocol": "openid-connect",
    "enabled": true
  }'
```

### 2.3. Create a user

In the Keycloak admin console, select realm **osac** > **Users** > **Add user**:

1. Set a username and enable the account.
2. Go to the **Credentials** tab, set a password with **Temporary: Off**.

### 2.4. Configure the fulfillment trusted issuer

The fulfillment-service must advertise the **external** Keycloak URL as the trusted token issuer. Otherwise the UI proxy discovers an internal URL and the browser cannot reach it.

Find the `--grpc-authn-trusted-token-issuers` flag in the fulfillment gRPC server deployment and set it to the external route:

```bash
--grpc-authn-trusted-token-issuers=https://keycloak-keycloak.apps.<cluster-domain>/realms/osac
```

Restart the deployment and verify:

```bash
curl -sk https://fulfillment-internal-api-<namespace>.apps.<cluster-domain>/api/fulfillment/v1/capabilities | jq .
```

Expected output:

```json
{
  "authn": {
    "trusted_token_issuers": [
      "https://keycloak-keycloak.apps.<cluster-domain>/realms/osac"
    ]
  }
}
```

## 3. Prepare TLS trust

The Helm chart requires ConfigMaps with PEM-encoded CA certificates to establish TLS trust with the fulfillment API and the OIDC provider (Keycloak). The chart mounts these as volumes — it does **not** use `*_TLS_INSECURE` flags.

### 3.1. Identify the CA bundle

The OSAC installer typically creates a `ca-bundle` ConfigMap in the `osac` namespace with the key `bundle.pem`. Verify it exists:

```bash
oc get configmap -n <namespace> ca-bundle -o jsonpath='{.data.bundle\.pem}' | openssl x509 -noout -subject
```

If the fulfillment-service and Keycloak certificates are signed by the same CA (common in OSAC deployments), the same ConfigMap can be used for both chart parameters.

### 3.2. Create a CA bundle (if it does not exist)

If no `ca-bundle` ConfigMap exists, create one from the CA that signed the fulfillment and Keycloak certificates:

```bash
# Extract the CA from an existing TLS secret (e.g. fulfillment-api-tls)
oc get secret -n <namespace> fulfillment-api-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca-bundle.pem

# If Keycloak uses a different CA, append it
oc get secret -n keycloak keycloak-tls-cert -o jsonpath='{.data.ca\.crt}' | base64 -d >> /tmp/ca-bundle.pem

# Create the ConfigMap
oc create configmap ca-bundle -n <namespace> --from-file=bundle.pem=/tmp/ca-bundle.pem
```

## 4. Deploy with Helm

> **Warning:** the container image must match the Helm chart version. Images built before the chart was introduced (commit `cca7be2`) do not support the CA-bundle volume mounts and will fail with TLS errors. Use the default chart image or rebuild from current `main`.

### 4.1. Identify the fulfillment internal Service

```bash
oc get svc -n <namespace> | grep fulfillment-internal-api
```

Note the Service name and port (e.g. `fulfillment-internal-api`, port `8001/TCP`).

### 4.2. Install or upgrade

```bash
helm upgrade --install osac-ui ./deploy/chart -n <namespace> \
  --set api.fulfillment.url=https://fulfillment-internal-api.<namespace>.svc.cluster.local:<port> \
  --set api.fulfillment.certs.caBundle.configMap=ca-bundle \
  --set auth.certs.caBundle.configMap=ca-bundle
```

To use a custom image instead of the chart default (`ghcr.io/osac-project/osac-ui:main`):

```bash
  --set images.ui=quay.io/<your-org>/osac-ui:latest
```

Key points:

- **`api.fulfillment.url`**: use the **internal Service URL** (not the external route) to avoid TLS hostname mismatches. Do **not** append `/api` — the proxy adds the path prefix automatically.
- **`api.fulfillment.certs.caBundle.configMap`** and **`auth.certs.caBundle.configMap`**: names of ConfigMaps in the release namespace containing PEM-encoded CA certificates. If both services share the same CA, use the same ConfigMap for both.

For all available configuration parameters, see [`deploy/chart/README.md`](../deploy/chart/README.md).

### 4.3. Get the route URL

```bash
oc get route osac-ui -n <namespace> -o jsonpath='{.spec.host}'
```

## 5. Verify

### 5.1. Health check

```bash
curl -sk https://$(oc get route osac-ui -n <namespace> -o jsonpath='{.spec.host}')/health | jq .
# {"status":"ok"}
```

### 5.2. OIDC discovery

```bash
curl -sk https://$(oc get route osac-ui -n <namespace> -o jsonpath='{.spec.host}')/api/login?redirect_base=https://$(oc get route osac-ui -n <namespace> -o jsonpath='{.spec.host}') | jq .url
```

The URL must contain the **external** Keycloak hostname, not `svc.cluster.local`.

### 5.3. Browser login

Open the **osac-ui** route URL in a browser. You should be redirected to Keycloak, log in with the user created in step 2.3, and land on the OSAC dashboard.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `could not determine OIDC issuer` | Proxy cannot reach the fulfillment `/capabilities` endpoint. | Check `api.fulfillment.url`, verify connectivity with `curl` from inside the pod. Ensure the CA bundle ConfigMap is correct. |
| `/api/api/fulfillment/v1/...` (duplicated path) | `api.fulfillment.url` ends with `/api`. | Remove the trailing `/api` from the URL. The proxy appends `/api/fulfillment/v1/...` automatically. |
| Browser redirects to `svc.cluster.local` | Keycloak's OIDC discovery returns internal hostnames. | Set `KC_HOSTNAME` on the Keycloak deployment to the external route hostname. Update Authorino AuthConfig and fulfillment-controller accordingly. |
| `Client not found` at Keycloak login | The `osac-ui` client does not exist in the correct realm. | Create the client in realm **osac**, not master. Verify with the admin API. |
| `Invalid parameter: redirect_uri` | The redirect URI sent by the proxy does not match the Keycloak client configuration. | The Helm chart creates a route named `osac-ui` (hostname `osac-ui-<namespace>.apps.<cluster-domain>`). Update the Keycloak client's Valid redirect URIs and Web origins to match. |
| `x509: certificate signed by unknown authority` | The CA bundle ConfigMap does not contain the CA that signed the target certificate. | Verify the CA bundle matches the issuer: `oc get configmap ca-bundle -o jsonpath='{.data.bundle\.pem}' \| openssl x509 -noout -subject`. If using a custom image, ensure it was built from code that supports `OIDC_TLS_CA_FILE` (post chart introduction). |
| `x509: certificate is valid for X, not Y` | The Keycloak TLS certificate does not include the route hostname as a SAN. | Add the route hostname to the cert-manager `Certificate` resource's `dnsNames` list and restart Keycloak (see [section 2.1](#21-set-the-external-hostname)). |
| `context deadline exceeded` on OIDC discovery | Pod cannot reach Keycloak on the configured hostname/port. | Verify the Keycloak Service port (`oc get svc -n keycloak`) and that NetworkPolicies allow cross-namespace traffic. |
