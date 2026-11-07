# Deploy (EKS Auto Mode, one load balancer)

```
Browser ─> Cloudflare ─> AWS NLB (the only LB) ─> Traefik
   /realms /resources /admin ─> keycloak:8080
   everything else           ─> frontend:80 ── nginx.conf (unchanged) proxies
                                 /user-api/          ─> user-service:8000
                                 /transaction-api/   ─> transaction-service:8080
                                 /activity-api/      ─> activity-service:8001
                                 /finance-agent-api/ ─> finance-agent:9001
```

## 1. Clean up leftovers from earlier attempts

```bash
kubectl delete namespace ingress-nginx --ignore-not-found
kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found
kubectl delete ingressclass nginx --ignore-not-found
```

## 2. Fill in the secrets

Edit `k8s/secrets.yml` and replace every `CHANGE_ME`. Use letters and
digits only for the DB passwords; `openssl rand -hex 24` gives you one.

If the `banking` namespace already has database volumes, Postgres keeps
the passwords those volumes were created with. Either reuse them
(`kubectl -n banking get secret banking-postgres-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d`),
or start fresh:
`kubectl -n banking delete statefulset banking-postgres keycloak-postgres && kubectl -n banking delete pvc --all`.

## 3. Check the images

The manifests use `229378727509.dkr.ecr.eu-west-1.amazonaws.com/<service>:v1`.
Fix the `image:` line in any file where your repository or tag differs.

## 4. Apply everything, in the right order

```bash
kubectl apply --dry-run=server -k k8s/   # must show no errors
kubectl apply -k k8s/
kubectl -n banking get pods -w           # all 1/1 Running after ~3 minutes
kubectl -n traefik get svc traefik       # EXTERNAL-IP = the NLB hostname
```

Keycloak imports the `banking` realm automatically on first start. That
includes the `banking-frontend` and `banking-provisioner` clients and the
three banking roles.

## 5. DNS and Cloudflare

- `kunleoyeleye-bank.com`: CNAME to the Traefik NLB hostname, Proxied.
- SSL/TLS mode: **Full**. For **Full (strict)**, create a Cloudflare Origin
  Certificate, store it as secret `banking-tls` in the `banking` namespace,
  and uncomment `secretName` in `ingress.yml`.

## 6. Verify

```bash
curl -s https://kunleoyeleye-bank.com/frontend-health                 # healthy
curl -s https://kunleoyeleye-bank.com/realms/banking | head -c 80      # realm JSON
curl -s https://kunleoyeleye-bank.com/user-api/health                 # {"status":"ok"}
```

Then register a user on the site. In the Keycloak admin console
(`https://kunleoyeleye-bank.com/admin`), assign that user the
`banking-customer`, `banking-transact` and `banking-ai-agent` roles, and
sign in.

## Frontend image

`VITE_KEYCLOAK_URL` is baked in at build time and must be
`https://kunleoyeleye-bank.com`. You don't need to change any code; set it
in an env file before building:

```bash
cd techbleat-global-bank-frontend
echo "VITE_KEYCLOAK_URL=https://kunleoyeleye-bank.com" > .env.production
docker build -t 229378727509.dkr.ecr.eu-west-1.amazonaws.com/frontend:v1 -f dockerfile .
```

## Not on EKS Auto Mode?

On a standard EKS cluster:
- In `storageclass.yml`, change the `provisioner` to `ebs.csi.aws.com`, and
  install the EBS CSI driver add-on.
- In the Traefik Service in `ingress-controller.yml`, remove
  `loadBalancerClass` and add the annotation
  `service.beta.kubernetes.io/aws-load-balancer-type: nlb`.
