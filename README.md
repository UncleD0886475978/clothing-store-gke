<div align="center">

# 🧵 clothing-store-gke

### Threads & Co. live on Google Cloud — GKE Autopilot running the storefront + MySQL, in three commands.

Part of the **Business Builds** series — real-world themed database + DevOps projects:
one business per repo, a real managed Kubernetes cluster per cloud.

![Google Cloud](https://img.shields.io/badge/Google%20Cloud-GKE%20Autopilot-4285F4?logo=googlecloud&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-GKE-326CE5?logo=kubernetes&logoColor=white)
![MySQL](https://img.shields.io/badge/MySQL-8-4479A1?logo=mysql&logoColor=white)
![nginx](https://img.shields.io/badge/nginx-storefront-009639?logo=nginx&logoColor=white)
![Business Builds](https://img.shields.io/badge/Project-Business%20Builds-success)

</div>

---

> ## ⚠️ COST WARNING — read this first
>
> **GKE is NOT free-tier.** Autopilot charges per pod resource request plus a cluster
> management fee (one cluster per billing account gets a management-fee credit, which
> helps, but pods still bill). A learning cluster left running adds up — create it,
> learn, then run `./setup.sh destroy` **the same day**. Deleting the cluster is what
> stops the charges.

## 🚀 Quick start

**One line per step on a fresh Ubuntu/Debian VM** (the script installs kubectl and the
Google Cloud CLI itself, and checks that you're logged in):

```bash
curl -fsSL https://raw.githubusercontent.com/UncleD0886475978/clothing-store-gke/main/setup.sh | bash -s -- cluster
curl -fsSL https://raw.githubusercontent.com/UncleD0886475978/clothing-store-gke/main/setup.sh | bash -s -- deploy
curl -fsSL https://raw.githubusercontent.com/UncleD0886475978/clothing-store-gke/main/setup.sh | bash -s -- destroy
```

Already have the repo cloned? Same thing, locally:

```bash
./setup.sh cluster    # create the GKE Autopilot cluster + point kubectl at it
./setup.sh deploy     # deploy storefront + MySQL into the "threads" namespace
./setup.sh destroy    # delete everything (asks you to type "yes" first)
```

Before `cluster`, log in once and pick your project:

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

`deploy` prints the storefront's public LoadBalancer address when it's ready
(and a port-forward fallback if you don't want to wait for the IP).

## 🌟 What you get

| Feature | What you get |
|---|---|
| 🚀 **Three-command lifecycle** | `cluster` → `deploy` → `destroy`, with the script bootstrapping kubectl + gcloud (incl. the GKE auth plugin) on apt systems |
| ☸️ **GKE Autopilot** | No nodes to manage — Google runs the infrastructure, you just ship pods; the script creates the cluster with `create-auto` |
| 🛍️ **A real storefront** | 2 nginx replicas behind a LoadBalancer serving the Threads & Co. demo page (hero + product grid) from a ConfigMap |
| 🐬 **MySQL 8, done properly** | StatefulSet + 10Gi PVC + Secret, `mysqladmin ping` probes, and the store schema auto-loaded from a ConfigMap on first start |
| 🧾 **The store's real schema** | categories, products, variants, inventory, customers, orders, order_items, payments, promotions |
| 💸 **Cost honesty** | The warning above, repeated by the script — plus a destroy mode guarded by a typed `yes` |
| 🔧 **Same script shape as EKS/AKS** | `CLUSTER_NAME` / `REGION` / `NAMESPACE` overrides work the same way across the cloud tracks |

## 🏗️ How it fits together

```
                 ┌──────────────────── GKE Autopilot cluster: threads-store (us-central1)
                 │
   shoppers ─────┼──▶ LoadBalancer ──▶ storefront-web Service ──▶ nginx pods ×2
                 │                                                    │ page from
                 │                                                    ▼ ConfigMap
                 │   namespace: threads
                 │                                                   
                 │   storefront / back office ──▶ mysql Service ──▶ MySQL 8 StatefulSet
                 │                                                    │ schema from ConfigMap
                 │                                                    ▼ (initdb, first start)
                 │                                              PVC mysql-data (10Gi)
                 └────────────────────
```

- **Autopilot** provisions and manages the nodes; you pay per pod resource request.
- The **storefront page** is a single HTML file in the `storefront-page` ConfigMap, mounted
  into nginx at `/usr/share/nginx/html/index.html` — edit the ConfigMap, roll the pods, done.
  (It's a demo page; the comment in the HTML says where the real storefront build goes.)
- **MySQL** keeps its data on the `mysql-data` PVC and loads `schema.sql` from the
  `mysql-schema` ConfigMap via `/docker-entrypoint-initdb.d/` on first start only.

## 🧵 The Threads & Co. story — and where the database design lives

Threads & Co. is an online clothing store: a catalog of products with size/color variants,
live inventory, customers, orders, payments, and promotions. **This repo runs that store on
GKE.** The database design itself — the full schema, sample data, and the Docker/Kubernetes
database package — lives in the sibling repo
[clothing-store-database](https://github.com/UncleD0886475978/clothing-store-database)
(MySQL). This repo carries the same core schema as a ConfigMap so the cloud deployment is
self-contained; if you evolve the schema, evolve it there first.

## ⚙️ Overrides

| Variable | Default | Notes |
|---|---|---|
| `CLUSTER_NAME` | `threads-store` | |
| `REGION` | `us-central1` | Autopilot clusters are regional |
| `GCP_PROJECT` | your active gcloud project | `gcloud config get-value project` |
| `NAMESPACE` | `threads` | |
| `NODE_COUNT` / `NODE_SIZE` | `2` / `e2-medium` | Parity with the EKS/AKS scripts — **not used by Autopilot**, which manages nodes for you |

## ✅ Requirements

- A **Google Cloud project with billing enabled** (see the cost warning) and the
  Kubernetes Engine API — the script enables it for you
- **Ubuntu/Debian VM:** nothing else — `setup.sh` installs git/curl, kubectl
  (official `dl.k8s.io` binary), and the Google Cloud CLI (official apt repo,
  including `google-cloud-cli-gke-gcloud-auth-plugin`) when they're missing
- **Other platforms:** the script prints guidance and exits — install kubectl +
  gcloud manually, then re-run
- One interactive step the script can't do for you: `gcloud auth login`

## 🔌 Connect

```bash
# the storefront (public, from deploy output)
http://<LoadBalancer IP from ./setup.sh deploy>

# or port-forward instead (leave it open, browse http://localhost:8080)
kubectl -n threads port-forward svc/storefront-web 8080:80

# the database
kubectl -n threads port-forward svc/mysql 3306:3306
mysql -h 127.0.0.1 -u threads -p threads_store   # password: threads_change_me (demo default)
```

> ⚠️ The example secret uses `threads_change_me` / `threads_root_change_me` — fine on a
> throwaway learning cluster, **change them** in `k8s/mysql-secret.yaml` (copy the example
> and edit) for anything real. `setup.sh deploy` warns loudly when it has to use the example.

## 📁 Project layout

```
clothing-store-gke/
├── setup.sh              # THE script: cluster | deploy | destroy — bootstraps kubectl + gcloud
├── k8s/
│   ├── namespace.yaml                 # "threads" namespace
│   ├── storefront-page-configmap.yaml # the demo storefront HTML page
│   ├── web-deployment.yaml            # storefront-web: nginx ×2, page mounted from ConfigMap
│   ├── web-service.yaml               # LoadBalancer on port 80
│   ├── mysql-secret.example.yaml      # demo credentials (change-me)
│   ├── mysql-schema-configmap.yaml    # Threads & Co. schema.sql (initdb)
│   ├── mysql-pvc.yaml                 # 10Gi persistent storage
│   ├── mysql-statefulset.yaml         # MySQL 8, mysqladmin ping probes
│   └── mysql-service.yaml             # ClusterIP + headless service
└── README.md
```

## 👨‍👩‍👧 Sibling repos — Business Builds

- [zadc-liberia-database](https://github.com/UncleD0886475978/zadc-liberia-database) — PostgreSQL for the ZADC Inc. Liberia nonprofit (Zao Development Organization)
- [clothing-store-database](https://github.com/UncleD0886475978/clothing-store-database) — MySQL for the Threads & Co. clothing store (the database design this repo runs)
- [fast-food-database](https://github.com/UncleD0886475978/fast-food-database) — MongoDB for the QuickBite fast-food chain
- [nursing-home-eks](https://github.com/UncleD0886475978/nursing-home-eks) — AWS EKS for a nursing home
- [it-services-aks](https://github.com/UncleD0886475978/it-services-aks) — Azure AKS for an IT services company

## 🗺️ Roadmap

- [x] One-command GKE Autopilot cluster create / deploy / destroy
- [x] Storefront on a LoadBalancer with the page served from a ConfigMap
- [x] MySQL StatefulSet with schema auto-load
- [ ] Ingress + managed TLS certificate + custom domain
- [ ] Real storefront build (CI image) replacing the ConfigMap demo page
- [ ] Horizontal Pod Autoscaling on the storefront
- [ ] Cloud SQL for MySQL as the managed-database option

---

<div align="center">

**Threads & Co. on GKE — built to learn cloud Kubernetes by doing, one business at a time.** 🧵

</div>
