# traefik-svc

> The fleet's Traefik configuration: the single ingress every service routes
> through. Part of [blm](https://github.com/janearc/blm). This is *configuration*,
> not a fork — it carries no Traefik source, only the manifests that shape the one
> edge.

## The edge

```
cloudflared  ->  traefik  ->  service
 (tunnel)       (ingress)     (Deployment + Service in namespace `fleet`)
```

cloudflared is the only outbound connector; traefik is the only ingress. A
request admitted by Cloudflare Access reaches traefik's `web` entrypoint (`:80`)
and is matched to a service by hostname. Services expose nothing to the host
directly — no NodePort, no hostPort. One edge, one way in.

## One traefik, not two

k3s ships Traefik as its built-in ingress controller. traefik-svc configures
*that* traefik through a `HelmChartConfig` (values merged onto the bundled chart)
instead of deploying a second one. A second traefik would be a second edge
contending for the same `:80` — exactly what the one-ingress model exists to
prevent. The bundle already covers what the fleet needs (the `web` entrypoint,
CRD-based routing, the dashboard), so a hand-rolled deployment would be cost for
no capability gained.

The trade-off, recorded: the bundled traefik's lifecycle belongs to k3s, so a k3s
upgrade can move its version or its defaults. traefik-svc pins only the values the
fleet depends on and lets k3s own the rest, so an upgrade flows through without
silently dropping fleet config.

## What's here

| File | Role |
|------|------|
| `kube/helmchartconfig.yaml` | the values merged onto k3s's bundled Traefik |
| `kube/ingressroute-template.yaml` | the template each service copies to attach itself |
| `kube/namespace.yaml` | the `fleet` namespace |
| `kube/kustomization.yaml` | ties the manifests together |
| `kube/NOTES.md` | the full ingress design and the decisions behind it |

## Secrets

Traefik writes real TLS private keys to `acme.json` at runtime. That file, along
with any `*.env`, `*.pem`, `*.key`, or `certs/`, is gitignored and never enters
this repo.
