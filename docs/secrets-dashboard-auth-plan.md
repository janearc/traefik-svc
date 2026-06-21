# Traefik dashboard basicauth — Kube Secrets migration plan

Status: planned, not yet applied. Author: max toegang. Drafted by claude ·
claude-opus-4-8; reviewed by max.

## Why this exists

The fleet ingress is k3s's bundled traefik, configured through
`kube/helmchartconfig.yaml`. That overlay sets:

```
api:
  dashboard: true
  insecure: true
```

`insecure: true` mirrors the compose mesh's `--api.insecure`. It exposes the
dashboard/API on traefik's internal `traefik` entrypoint (:8080) with **no
authentication** — the only thing in front of it is cloudflared + Cloudflare
Access. That is a single layer: anything that reaches traefik (a misrouted
hostname, a future in-cluster caller, a relaxed Access policy) reaches an
unauthenticated read view of every route, service, and middleware in the fleet.
The overlay's own comment anticipates this: "If the edge posture tightens, turn
this off and front the dashboard with an IngressRoute + auth Middleware
instead." This is that change, as a plan.

The migration turns `api.insecure` **off**, routes the dashboard through a
normal `IngressRoute` on the `web` entrypoint, and protects it with a
`basicAuth` Middleware whose credentials live in a Kube Secret — following the
fleet's `cloudflared-tunnel` reference shape
(`/Users/jane/work/cloudflared/kube`): a named Secret, scoped RBAC, value
injected by max via stdin, never committed.

No credential value appears in this document, any manifest in this repo, or any
command an agent can see.

## What the secret is

A traefik `basicAuth` Middleware reads an htpasswd-format users list from a
Secret. The secret material is the **htpasswd line(s)** — `user:hashed-password`
where the hash is bcrypt (or MD5-apr1). The plaintext password is never stored;
only the bcrypt hash, and that hash is itself treated as a secret because it is
offline-crackable. One key, `users`, holding one htpasswd line per dashboard
operator.

This is a meaningfully smaller secret than the kafka case: one Secret, one key,
one Middleware. It is the closest analogue to `cloudflared-tunnel` in the fleet.

## Secret — reference shape (NO VALUES)

Following `cloudflared-tunnel`: created out-of-band by max via stdin, **never**
committed with a `data:`/`stringData:` block, **never** listed in
`kustomization.yaml` (an applied valueless Secret would mask the real one). It
exists in the repo as documentation of the shape only.

```
# REFERENCE SHAPE ONLY — do not apply, do not add to kustomization.yaml.
# apiVersion: v1
# kind: Secret
# metadata:
#   name: traefik-dashboard-auth
#   namespace: kube-system          # MUST match the dashboard route's ns — see below
#   labels:
#     app.kubernetes.io/name: traefik
#     app.kubernetes.io/part-of: fleet
# type: Opaque
# # key `users` is created out-of-band by the kubectl command below.
# #   users: <one htpasswd line per operator, bcrypt-hashed>
# # NO data:/stringData: block — the value never appears in this repo.
```

Namespace note: traefik's `basicAuth` Middleware reads its `secret` from the
**same namespace as the Middleware**, and a Middleware referenced by an
IngressRoute must be reachable from that route. Because the dashboard belongs to
the bundled traefik in `kube-system`, the dashboard IngressRoute, its
Middleware, and this Secret all live in `kube-system` (not `fleet`). This is the
one route the fleet runs in `kube-system`, precisely because the dashboard is
traefik's own surface.

## Injecting the value (max runs this from his own terminal)

The htpasswd line never enters a file, git, or an agent context. Generate it
locally (`htpasswd -nbB <user> <password>` — bcrypt) and stream it into stdin so
it stays off disk and out of shell history:

```
htpasswd -nbB max - | kubectl create secret generic traefik-dashboard-auth \
  --from-file=users=/dev/stdin -n kube-system
# or: run htpasswd interactively, copy the user:hash line, then:
kubectl create secret generic traefik-dashboard-auth \
  --from-file=users=/dev/stdin -n kube-system
# paste the htpasswd line, then Ctrl-D on its own line.
```

For multiple operators, concatenate the htpasswd lines (one per line) before the
Ctrl-D.

Rotate by recreating the Secret (`kubectl create ... --dry-run=client -o yaml |
kubectl apply -f -` via the same stdin paste). traefik watches the Secret and
picks up the change; no restart is required for a Middleware secret, but if in
doubt `kubectl rollout restart deployment/traefik -n kube-system`.

The Secret must exist before the Middleware resolves, or traefik logs a
reference error and the dashboard route returns 500 — fail-closed, matching the
fleet's posture.

## RBAC — named-resource Role + RoleBinding (reference pattern)

The bundled traefik controller already has a ClusterRole that lets it read
Secrets cluster-wide (that is how any traefik basicAuth/TLS secret works), so
strictly the controller can already read this Secret. To keep the fleet's
*named, least-privilege* convention visible and auditable — the same shape as
`cloudflared-secret-reader` — this plan adds an explicit named Role + RoleBinding
scoped to the one Secret, bound to traefik's ServiceAccount. It documents intent
and survives any future tightening of the bundle's ClusterRole.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: traefik-dashboard-secret-reader
  namespace: kube-system
  labels:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/part-of: fleet
rules:
  # scoped to exactly the one named Secret — not all secrets in kube-system.
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["traefik-dashboard-auth"]
    verbs: ["get", "watch"]   # watch: traefik reloads the Middleware on change
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: traefik-dashboard-secret-reader
  namespace: kube-system
  labels:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/part-of: fleet
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: traefik-dashboard-secret-reader
subjects:
  # the bundled traefik's ServiceAccount. Confirm the exact name on the cluster
  # (`kubectl get sa -n kube-system | grep traefik`); k3s's chart names it
  # `traefik`. Bind to that SA, not the namespace default.
  - kind: ServiceAccount
    name: traefik
    namespace: kube-system
```

Unlike the cloudflared/kafka cases — where the workload's *own* SA reads its own
Secret — here the **traefik controller** reads the Secret on the dashboard's
behalf (it is the controller that resolves Middleware secrets). So the
RoleBinding subject is traefik's controller SA, not a per-route SA. The named
Role still pins access to the single Secret. (We do not, and cannot from this
repo, create a ServiceAccount for the bundled controller — k3s owns it; we only
add a Role/RoleBinding referencing it.)

## How the dashboard consumes it

Three new objects (a new `kube/dashboard.yaml` in this repo), plus one change to
the existing `helmchartconfig.yaml`:

1. **Turn `api.insecure` off** in `kube/helmchartconfig.yaml`:

   ```yaml
   api:
     dashboard: true
     insecure: false     # was true — dashboard no longer on the raw :8080
   ```

   With `insecure: false`, the dashboard is served by traefik's internal `api@internal`
   service and is reachable only through a router that explicitly targets it —
   which the IngressRoute below provides, now gated by auth.

2. **basicAuth Middleware** referencing the Secret (no value here):

   ```yaml
   apiVersion: traefik.io/v1alpha1
   kind: Middleware
   metadata:
     name: traefik-dashboard-auth
     namespace: kube-system
     labels:
       app.kubernetes.io/name: traefik
       app.kubernetes.io/part-of: fleet
   spec:
     basicAuth:
       secret: traefik-dashboard-auth   # the Secret's name; key `users` is read
       removeHeader: true               # strip Authorization before proxying on
   ```

3. **IngressRoute** for the dashboard on the `web` entrypoint, with the
   Middleware attached and pointing at the internal API service:

   ```yaml
   apiVersion: traefik.io/v1alpha1
   kind: IngressRoute
   metadata:
     name: traefik-dashboard
     namespace: kube-system
     labels:
       app.kubernetes.io/name: traefik
       app.kubernetes.io/part-of: fleet
   spec:
     entryPoints:
       - web                # TLS terminates at Cloudflare; tunnel forwards :80
     routes:
       - kind: Rule
         # the hostname Cloudflare Access fronts for the dashboard. Keep it on a
         # dedicated host (e.g. traefik.local), behind an Access policy at least
         # as strict as the basicAuth this adds — defense in depth, not either/or.
         match: Host(`traefik.local`) && PathPrefix(`/dashboard`) || Host(`traefik.local`) && PathPrefix(`/api`)
         services:
           - kind: TraefikService
             name: api@internal          # traefik's built-in dashboard/API service
         middlewares:
           - name: traefik-dashboard-auth
   ```

   `api@internal` is traefik's internal service handle for the dashboard; it is
   addressable as a `TraefikService` only when `api.dashboard: true` (which we
   keep) and is no longer exposed insecurely (which we just turned off). The
   `basicAuth` Middleware gates it; Cloudflare Access stays in front as the outer
   layer.

## Defense in depth, not replacement

Cloudflare Access remains the outer gate. The basicAuth Middleware is the inner
gate so the dashboard is never unauthenticated *inside* the cluster — closing the
single-layer exposure the current `insecure: true` leaves. Both layers stay on;
this change adds the inner one, it does not relax the outer one.

## Migration steps (ordered)

1. **Generate the htpasswd line** on max's box (`htpasswd -nbB <user>
   <password>`, bcrypt). Nothing touches the repo.
2. **Inject the Secret** via the stdin command above into `kube-system`.
3. **Add `kube/dashboard.yaml`** (Middleware + IngressRoute above). Optionally
   add the named Role/RoleBinding (`kube/rbac.yaml`) to keep the least-privilege
   convention explicit.
4. **Edit `kube/helmchartconfig.yaml`**: flip `api.insecure` to `false`.
5. **Decide kustomization wiring.** `helmchartconfig.yaml` is already deliberately
   the primary agent's one-time `kube-system` step and is *not* in
   `kustomization.yaml`. The dashboard route + Middleware are also `kube-system`
   objects gating traefik's own surface, so they follow the same handling — list
   them in a `kube-system`-scoped apply the primary agent runs, not the
   `fleet`-namespace service loop. Do **not** add the Secret to any kustomization.
6. **Validate offline**: `kubectl kustomize kube/ | kubeconform -strict
   -ignore-missing-schemas` (IngressRoute/Middleware/HelmChartConfig are CRDs, so
   `-ignore-missing-schemas` is required — see NOTES.md).
7. **Primary agent applies** the `helmchartconfig.yaml` overlay (k3s reconciles
   it onto the bundled chart) and the dashboard objects. Subagents do not apply.
   k3s re-rolls the bundled traefik when the HelmChartConfig changes.
8. **Verify**: hitting the dashboard host now prompts for basicAuth and rejects a
   missing/wrong credential with 401; a correct credential loads the dashboard.
   Confirm the raw internal `:8080` no longer serves the dashboard
   unauthenticated.

## Sequencing caveat

Apply the **Secret first**, then the Middleware/IngressRoute, then flip
`api.insecure: false`. If `insecure` is turned off before the authenticated
route exists, the dashboard is briefly unreachable (acceptable — fail-closed).
If the Middleware is applied before its Secret exists, the route returns 500
until the Secret lands. Neither order leaves the dashboard unauthenticated, which
is the property we are protecting.
