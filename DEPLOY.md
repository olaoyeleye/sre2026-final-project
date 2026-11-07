# Deploying Techbleat Global Bank on EKS with Argo CD and Istio

No application code changes. Everything below is deployment configuration.

## How traffic flows

```
Browser ──HTTPS──> Cloudflare ──HTTPS──> AWS NLB ──> Istio ingress gateway (TLS: Let's Encrypt)
                                                         │  (mTLS from here on)
       https://kunleoyeleye-bank.com                     │
         /realms /resources /admin ──────────────────────┼──> keycloak:8080
         /user-api/*          (prefix stripped) ─────────┼──> user-service:8000
         /transaction-api/*   (prefix stripped) ─────────┼──> transaction-service:8080
         /activity-api/*      (prefix stripped) ─────────┼──> activity-service:8001
         /finance-agent-api/* (prefix stripped) ─────────┼──> finance-agent:9001
         /*  ────────────────────────────────────────────┴──> frontend:80
```

This is the same routing the frontend already expects: `src/App.jsx` calls
the relative `/…-api` paths, and `src/auth.js` uses `VITE_KEYCLOAK_URL`.
The gateway does what the frontend's own `nginx.conf` does in Docker Compose.

Inside the mesh:
- **STRICT mTLS** between all app pods.
- **Deny-by-default** authorization, with only the real call paths allowed.
- **JWT validation and role checks at the sidecar.** Tokens with a bad
  signature, wrong issuer, wrong audience or that have expired are rejected,
  and the right role is required:
  - `banking-customer` to read
  - `banking-transact` to move money
  - `banking-ai-agent` to use the AI assistant

Postgres, Kafka and Redis run outside the mesh and are protected by NetworkPolicies.

## Repository layout

```
terraform/                 VPC + EKS cluster with 3 managed node groups
argocd/
  project.yml              AppProject "banking"
  root.yml                 app-of-apps, applied once by hand
  apps/
    00-aws-load-balancer-controller.yml wave -4  creates the NLB
    01-istio-base.yml      wave -3  Istio CRDs
    02-istiod.yml          wave -2  Istio control plane
    03-istio-gateway.yml   wave -1  ingress gateway + NLB
    04-cert-manager.yml    wave -1  certificates
    05-banking-platform.yml wave 0  k8s/platform
    06-banking-app.yml     wave 1   k8s/app
    07-banking-mesh.yml    wave 2   k8s/mesh
k8s/
  platform/   storageclass.yml (default gp3, EBS CSI driver)
  app/        ns, config, keycloak-realm, service, the two Postgres DBs,
              redis, kafka, keycloak, user, transaction, activity,
              finance-agent, frontend
  mesh/       ingress.yml (Gateway + VirtualService), security.yml,
              certificate.yml
scripts/
  create-secrets.sh        all secrets, kept out of Git
```

Old files this replaces: `k8s/*.yml` at the top level (including the
duplicate `config.yml`/`configmap.yml` and `traefik.yml`/`ingress-controller.yml`
pairs), `k8s/xxx`, and the `secret(s).yml` files. Delete them; see step 2.

## Node groups

| Node group | Label | Taint | Runs |
|---|---|---|---|
| `system` (2× m6i.large) | `workload=system` | none | Istio, ingress gateway, cert-manager, LB controller |
| `apps` (3× m6i.xlarge) | `workload=apps` | none | frontend, Keycloak, user / transaction / activity / finance-agent |
| `data` (3× r6i.large, one per AZ) | `workload=data` | `dedicated=data:NoSchedule` | Postgres ×2, Kafka ×3, Redis |

Each manifest pins its pods with a `nodeSelector`. The data stores also
tolerate the taint, so nothing else can land on the data nodes. Argo CD and
the EKS add-ons (CoreDNS etc.) can run on any untainted node.

---

## 1. Create the cluster (Terraform)

Run this from the EC2 box. It needs Terraform 1.10+ and AWS credentials
allowed to create a VPC, EKS and IAM.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # adjust (API CIDR, NAT, sizes)
terraform init
terraform plan -out tfplan
terraform apply tfplan                          # ~15-20 minutes
$(terraform output -raw configure_kubectl)      # point kubectl at the new cluster
kubectl get nodes -L workload                   # 8 nodes: 2 system, 3 apps, 3 data
terraform output vpc_id
cd ..
```

This builds a **new** VPC and cluster alongside your current Auto Mode
cluster. The new one starts with empty databases; the realm is
auto-imported. Delete the old cluster when you've switched over.

Put the `vpc_id` output into `argocd/apps/00-aws-load-balancer-controller.yml`
(`vpcId:`). Also update `clusterName`/`region` there if you changed them.

## 2. Put the files in the repo

From the repo root on the EC2 box:

```bash
git pull origin feat-dev
# Remove the old flat k8s folder (all content is replaced)
git rm -r --cached k8s >/dev/null; rm -rf k8s
# Unzip the new layout into the repo root (creates argocd/ k8s/ scripts/ DEPLOY.md)
unzip -o ~/banking-gitops.zip -d .
chmod +x scripts/create-secrets.sh
```

**Check the image names.** `k8s/app/*.yml` use
`229378727509.dkr.ecr.eu-west-1.amazonaws.com/<service>:v1`. Check they
exist in ECR and fix any that differ:

```bash
aws ecr describe-repositories --region eu-west-1 --query 'repositories[].repositoryUri' --output table
grep -rn 'image: 2293' k8s/app/
```

Then commit and push. Argo CD deploys from Git, so it must be on GitHub:

```bash
git add -A
git commit -m "Terraform EKS (3 node groups) + Argo CD + Istio"
git push origin feat-dev
```

Never commit `terraform/terraform.tfvars` if it holds anything sensitive,
or the `.terraform/` folder and `*.tfstate` files:

```bash
printf '.terraform/\n*.tfstate*\ntfplan\n' >> .gitignore
```

## 3. Install Argo CD

Make sure kubectl points at the **new** cluster (`kubectl config current-context`).

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.0/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

**Let sync waves wait for child apps to become healthy.** Without this,
Argo CD would start the banking app before Istio is ready:

```bash
kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"resource.customizations.health.argoproj.io_Application":"hs = {}\nhs.status = \"Progressing\"\nhs.message = \"\"\nif obj.status ~= nil then\n  if obj.status.health ~= nil then\n    hs.status = obj.status.health.status\n    if obj.status.health.message ~= nil then\n      hs.message = obj.status.health.message\n    end\n  end\nend\nreturn hs\n"}}'
kubectl -n argocd rollout restart deploy argocd-repo-server statefulset argocd-application-controller
```

**If the GitHub repo is private,** give Argo CD read access. Use a
fine-grained token with Contents: Read-only on this repo:

```bash
kubectl -n argocd create secret generic repo-sre2026 \
  --from-literal=type=git \
  --from-literal=url=https://github.com/olaoyeleye/sre2026-final-project.git \
  --from-literal=username=olaoyeleye \
  --from-literal=password=<GITHUB_TOKEN>
kubectl -n argocd label secret repo-sre2026 argocd.argoproj.io/secret-type=repository
```

**Open the UI** (user `admin`):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8443:443
# then browse https://localhost:8443 (from your laptop: ssh -L 8443:localhost:8443 ubuntu@<ec2-ip>)
```

## 4. Create the secrets (never in Git)

```bash
export OPENAI_API_KEY=sk-...           # finance-agent
export CLOUDFLARE_API_TOKEN=...        # Cloudflare token: Zone > DNS > Edit for kunleoyeleye-bank.com
./scripts/create-secrets.sh
```

On a fresh cluster, strong random passwords are generated. Re-running the
script keeps existing values, which matters because Postgres only reads its
password when the volume is first created. The Keycloak `banking-provisioner` client
secret is generated once and shared by Keycloak (realm import) and user-service.

## 5. Hand the cluster to Argo CD

```bash
kubectl apply -f argocd/project.yml -f argocd/root.yml
kubectl -n argocd get applications -w
```

Order of events: AWS Load Balancer Controller → Istio CRDs → istiod →
gateway (NLB created) and cert-manager → storage class → banking app (app
pods start **with sidecars**, showing `2/2` READY) →
gateway routes, mTLS and the certificate. Expect about 5–10 minutes. All
apps should end `Synced` / `Healthy`.

```bash
kubectl -n banking get pods                 # app pods 2/2, data stores 1/1
kubectl -n istio-ingress get svc istio-ingressgateway   # note EXTERNAL-IP (NLB hostname)
kubectl -n istio-ingress get certificate    # READY=True once DNS is in place
```

## 6. DNS and Cloudflare

- The load balancer is **new**, so point DNS at the gateway's NLB hostname
  from the command above.
  - Root `kunleoyeleye-bank.com`: CNAME to the NLB hostname, Proxied.
    Cloudflare flattens a CNAME at the root automatically.
  - Delete the old `auth`/`users`/`transactions`/`activity`/`agent` records. They aren't used.
- SSL/TLS mode: **Full (strict)**.

## 7. Verify

```bash
curl -sI http://kunleoyeleye-bank.com | head -3                       # 301 -> https
curl -s  https://kunleoyeleye-bank.com/frontend-health                # healthy
curl -s  https://kunleoyeleye-bank.com/realms/banking | head -c 80    # realm JSON (auto-imported)
curl -s  -o /dev/null -w '%{http_code}\n' https://kunleoyeleye-bank.com/transaction-api/balance/x   # 403: no token
curl -s  -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer junk' https://kunleoyeleye-bank.com/transaction-api/balance/x   # 401: bad token
```

Then in a browser:
1. **Register** a user on the site.
2. **Assign roles.** Log in to the Keycloak admin console at
   `https://kunleoyeleye-bank.com/admin` (password command printed by
   `create-secrets.sh`). Go to banking realm → Users → *user* → Role mapping
   → Assign role, and add the **realm roles** `banking-customer`,
   `banking-transact` and `banking-ai-agent`.
3. **Sign in** and use the dashboard.

## Day-2: how changes are deployed

- **New image:** build and push to ECR with a new tag, change `image:` in
  `k8s/app/<service>.yml`, commit, push. Argo CD rolls it out.
- **Config change:** edit `k8s/app/config.yml`, then push. Pods read env
  vars only at start, so run `kubectl -n banking rollout restart deploy/<name>`.
- **Manual `kubectl edit`:** Argo CD reverts it (selfHeal). Change Git instead.
- **`banking-app` has prune off** so a bad commit can never delete the
  databases. Remove resources from it deliberately with `kubectl delete`.

## Building the frontend image (unchanged Dockerfile)

`VITE_KEYCLOAK_URL` is baked in at build time. Without touching code, put it
in a Vite env file before `docker build`. Vite reads it automatically, and
`.dockerignore` doesn't exclude it:

```bash
cd techbleat-global-bank-frontend
echo "VITE_KEYCLOAK_URL=https://kunleoyeleye-bank.com" > .env.production
docker build -t 229378727509.dkr.ecr.eu-west-1.amazonaws.com/frontend:v2 -f dockerfile .
```

## Notes and limits

- **Pod security:** the `banking` namespace enforces `privileged` because the
  sidecar's `istio-init` container needs NET_ADMIN. Installing the Istio CNI
  plugin removes that need, and you can tighten back to `baseline`.
- **NetworkPolicies** are enforced by the VPC CNI (`enable_network_policy`
  in Terraform). They guard Postgres, Kafka and Redis. If a data store's
  probes start failing after this is enabled, set the variable to `false`
  and re-apply. Istio's mTLS and authorization still protect the apps.
- **Node group sizes are fixed** between `min_size` and `max_size`. The HPAs
  add pods, but nothing adds nodes yet. For automatic node scaling, add
  Cluster Autoscaler or Karpenter later.
- **Data nodes and AZs:** EBS volumes are tied to one AZ. The data group has
  one node per AZ; if a node is replaced, its pods wait for a node in the
  same AZ, which the node group recreates automatically.
- **Keycloak admin console** is reachable at `/admin` on the public domain.
  Consider a Cloudflare Access rule or WAF IP allow-list on `/admin`.
- **What the mesh does not do:** it checks the token and role, but not
  *account ownership*. A `banking-customer` could request another user's ID.
  That check needs code in the services, as the project brief notes.
- **Realm import** runs only when the `banking` realm doesn't exist. If you
  created it by hand earlier, delete it in the admin console and restart
  Keycloak (`kubectl -n banking rollout restart deploy/keycloak`) to get the
  imported version.
