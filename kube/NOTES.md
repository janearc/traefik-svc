# Fleet ingress on Kubernetes

This directory is the ingress foundation for the fleet's move from the
docker-compose mesh to k3d. It establishes the single edge every migrated
service routes through and the template each service copies to attach itself.

## The edge, unchanged in shape

```
cloudflared  ->  traefik  ->  service
 (tunnel)       (ingress)     (Deployment + Service in ns fleet)
```

cloudflared is the only outbound connector; traefik is the only ingress. A
request admitted by Cloudflare Access reaches traefik's `web` entrypoint (:80)
and is matched to a service by hostname. Services expose nothing to the host
directly — no NodePort, no hostPort. This is the same topology the compose mesh
ran; only the mechanics move into Kubernetes.

## Decision: reuse k3s's bundled traefik (not a second traefik)

k3s installs traefik as its built-in ingress controller (traefik v3 on k3s
v1.35.x). It comes up in `kube-system` as a k3s-managed Helm release, with the
IngressRoute / Middleware / TLSOption CRDs and the controller's RBAC already
present. That is one running edge.

We configure that traefik through `helmchartconfig.yaml` (a `HelmChartConfig`
whose values are merged onto the bundled chart) rather than deploying our own
traefik Deployment + CRDs + RBAC. A second traefik would be a second edge
contending for the same role and the same :80 — exactly what the one-ingress
model exists to prevent. The bundle covers every need the compose traefik had
(the `web` entrypoint, CRD-based routing, the dashboard), so a hand-rolled
deployment would be cost with no capability gained.

The trade-off, recorded: the bundled traefik's lifecycle belongs to k3s. A k3s
upgrade can change traefik's version or default values. We pin only the values
the fleet depends on in `helmchartconfig.yaml` and let k3s own the rest, so an
upgrade flows through without silently dropping fleet config. If a future need
arises that the bundle genuinely cannot express, the migration is: disable the
bundle (`--disable=traefik` at cluster create) and promote
`ingressroute-template.yaml`'s controller assumptions into a deliberate traefik
Deployment here. We are not there.

## How a service attaches a route

1. Copy `ingressroute-template.yaml` into your service's repo as
   `kube/ingressroute.yaml`.
2. Replace every `<PLACEHOLDER>`:
   - `<SERVICE>` — your service name (also its label and, by convention, the
     IngressRoute and Service object names).
   - the `match` rule — the public hostname Cloudflare Access fronts for this
     service, e.g. `Host(`obs.local`)`, optionally narrowed with
     `&& PathPrefix(`/...`)`.
   - `<PORT>` — the `port` of your `kube/service.yaml` (the Service port, not
     necessarily the container's targetPort).
3. Keep `namespace: fleet` and `entryPoints: [web]`. The Service the route names
   must be in `fleet` too — cross-namespace routing is off.
4. List `ingressroute.yaml` in your service's `kube/kustomization.yaml`.
5. Validate offline (below). Hand the apply to the primary agent — do not apply.

Need auth, prefix-stripping, headers, or rate limits? Define a `Middleware` CRD
alongside the route and reference it under the route's `middlewares:` — the
template carries a worked `stripPrefix` example.

## Validation (offline — no cluster, no apply)

`kubectl apply --dry-run=client` needs a reachable API server to resolve types,
so on a workstation with no live cluster it is not the offline check it sounds
like. The offline validator is `kubeconform`, which checks manifests against
schemas without a cluster:

```
# the edge foundation (this dir):
kubectl kustomize kube/ | kubeconform -strict -ignore-missing-schemas

# a single file, e.g. a service's filled-in route:
kubeconform -strict -ignore-missing-schemas kube/ingressroute.yaml
```

`-ignore-missing-schemas` is required: IngressRoute and HelmChartConfig are
CRDs, and their schemas are not in kubeconform's built-in set, so it would
otherwise fail on them. With the flag, kubeconform fully validates the built-in
kinds (Namespace) and confirms the CRD objects are well-formed YAML with the
right apiVersion/kind, while skipping their unknown schemas. When the cluster is
up, the primary agent gets the real server-side check for free via
`kubectl apply --dry-run=server`.

## Files

| file | what |
|------|------|
| `namespace.yaml` | the `fleet` namespace services live in |
| `helmchartconfig.yaml` | overlay configuring k3s's bundled traefik (a `kube-system` object — primary agent's one-time step) |
| `ingressroute-template.yaml` | copy-me host-route template; not deployed from here |
| `kustomization.yaml` | brings up namespace + helmchartconfig (not the template) |

## author

max toegang <max.toegang@ftml.net>
claude · claude-opus-4-8 (drafted these manifests and notes; reviewed by max)
