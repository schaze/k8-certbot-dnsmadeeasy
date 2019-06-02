# k8-certbot-dnsmadeeasy
Simple docker image with certbot incl. dns-dnsmadeeasy plugin, kubectl and bash for certificate management in k8.

Entrypoint is taken over from certbot/certbot. 

I mainly use this with some mounted script (via configmaps) to run as a kubernetes cron job that updates my ssl certificates.
There are no scipts inside the image as I prefer to have this as flexible as possible, with the hope it can be usefull to others as well.

see https://hub.docker.com/r/schaze/k8-certbot-dnsmadeeasy

## Credits

This is derived from the work of:
 - https://github.com/choffmeister/kubernetes-certbot
 - https://github.com/dwnld/kubernetes-certbot
 - https://github.com/ixdy/kubernetes-certbot
 - https://github.com/pjmorr/kubernetes-certbot

## Usage example 

Watch for the `<<REPLACE ME>>` parts in the files and adjust as appropriate.
This example actually got quite lengthy, however if you have similar requirements to me you might get started faster due to this.

### TL;DR
1. Bring your scripts in the container
2. Setup config files as needed
3. Ensure RBAC is setup for kubectl to talk to the k8 api server
4. Provision storage for certbot data
5. Deploy a workload that periodically updates your certificates

### Scripts
Create a configmap with the scripts to run for renewal (see credits for implementation base):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-k8-certbot-scripts
  namespace: ingress-nginx
  labels:
    <<ALWAYS LABEL YOUR STUFF>>

data:
  renew_certs.sh: |-
    #!/bin/bash

    # Sleep 5 minutes so a crash looping pod doesn't punch let's encrypt.
    echo "Renewing cert in 5 minutes"
    sleep 300

    while IFS='=' read -r secret_name domains
    do
        /bin/bash ./run.sh $secret_name $domains
    done < /etc/letsencrypt-certs/ssl-certifcates.properties

  run.sh: |- 
    #!/bin/bash
    readonly SECRET_NAME=$1
    readonly DOMAINS=$2
    readonly DOMAIN_MAIN=$(echo $DOMAINS | sed 's/,.*//' | sed 's/\*\.//')
    readonly SECRET_NAMESPACE=${SECRET_NAMESPACE:-default}
    readonly STAGING=${STAGING:-}
    readonly DNSMADEEASY=${DNSMADEEASY:-/opt/certbot/dnsmadeeasy.ini}
    readonly ANNOTATIONS=${ANNOTATIONS:-}

    echo "========================================================================="
    echo "Generating certificate ${DOMAIN_MAIN}"
    echo "========================================================================="

    echo ""
    echo "cerbot start"
    echo "=============="
    echo ""
    certbot \
      --non-interactive \
      --agree-tos \
      --dns-dnsmadeeasy \
      --dns-dnsmadeeasy-credentials ${DNSMADEEASY} \
      --email "${LETS_ENCRYPT_EMAIL}" \
      --domains "${DOMAINS}" \
      ${STAGING:+"--staging"} \
      certonly
    echo ""
    echo "=============="
    echo "cerbot end"
    echo "=============="
    echo "Generating kubernetes secret ${SECRET_NAME} (namespace ${SECRET_NAMESPACE})"

    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: "${SECRET_NAME}"
      namespace: "${SECRET_NAMESPACE}"
      annotations:
        ${ANNOTATIONS}
    type: kubernetes.io/tls
    data:
      tls.crt: "$(cat /etc/letsencrypt/live/${DOMAIN_MAIN}/fullchain.pem | base64 | tr -d '\n')"
      tls.key: "$(cat /etc/letsencrypt/live/${DOMAIN_MAIN}/privkey.pem | base64 | tr -d '\n')"
    EOF
    echo ""
    echo "done"
    echo "========================================================================="
    echo "========================================================================="
    echo ""
    echo ""
```
### RBAC
You will need proper authorization to create and update the secret with the credentials (e.g. assuming we are in the ingress-nginx namespace):
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: certbot-update
  namespace: ingress-nginx
  labels:
    <<ALWAYS LABEL YOUR STUFF>>

---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: certbot-update-role
  namespace: ingress-nginx
  labels:
    <<ALWAYS LABEL YOUR STUFF>>

rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: certbot-update-rb
  namespace: ingress-nginx
  labels:
    <<ALWAYS LABEL YOUR STUFF>>

roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: certbot-update-role
subjects:
- kind: ServiceAccount
  name: certbot-update
  namespace: ingress-nginx
```
### Storage
I use a persistant volume claim to store the certbot files

```yaml
---
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: letsencrypt-data
  namespace: ingress-nginx
  labels:
    <<ALWAYS LABEL YOUR STUFF>>
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

### Configuration

The scripts use a configfile with the format:

```
<secretname1>=<domainname1>
<secretname2>=<domainname2>
...
```
E.g.
```
letsencrypt-ssl-secret1=*.mydomain1.org
letsencrypt-ssl-secret2=*.mydomain2.org
```
Here is an example:
```yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: letsencrypt-ssl-cfg
  namespace: ingress-nginx
  labels:
    <<ALWAYS LABEL YOUR STUFF>>

data:
  # there can be multiple lines for multiple secrets and domains
  ssl-certifcates.properties: |-
    <<secretname=domain>>

```

### DNS MadeEasy
Cofniguration as a secret with api key and secret for dns-madeeasy:
```yaml
kind: Secret
apiVersion: v1
metadata:
  name: dnsmade-easy-api
  namespace: ingress-nginx
  labels:
    <<ALWAYS LABEL YOUR STUFF>>
type: Opaque
data:
  dnsmadeeasy.ini:
    dns_dnsmadeeasy_api_key = <<YOUR API KEY>>
    dns_dnsmadeeasy_secret_key = << ZOUR SECRET KEY>>

```

### Cronjob
deploy a cronjob which will use the scripts (e.g.):

```yaml
apiVersion: batch/v1beta1
kind: CronJob
metadata:
  name: ingress-nginx-k8-certbot-dnsmadeeasy
  namespace: ingress-nginx
  labels:
    <<ALWAYS LABEL YOUR STUFF>>

spec:
  schedule: "30 0 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            <<ALWAYS LABEL YOUR STUFF>>
        spec:
          serviceAccountName: certbot-update
          restartPolicy: OnFailure
          containers:
            - name: certbot
              image: schaze/k8-certbot-dnsmadeeasy:latest
              imagePullPolicy: IfNotPresent
              command: ["/bin/bash", "/opt/certbot/renew_certs.sh"]
              resources:
              env:
                - name: SECRET_NAMESPACE
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.namespace
                - name: LETS_ENCRYPT_EMAIL
                  value: <<YOUR EMAIL HERE>>
                - name: DNSMADEEASY
                  value: /etc/dnsmadeeasy/dnsmadeeasy.ini
              volumeMounts:
                - mountPath: /etc/letsencrypt
                  name: letsencrypt-data
                - mountPath: /etc/letsencrypt-certs
                  name: letsencrypt-certs-config
                - mountPath: /etc/dnsmadeeasy
                  name: dnsmade-easy-api
                - mountPath: /opt/certbot/renew_certs.sh
                  subPath: renew_certs.sh
                  name: scripts
                - mountPath: /opt/certbot/run.sh
                  subPath: run.sh
                  name: scripts
          volumes:
            - name: letsencrypt-certs-config
              configMap:
                name: letsencrypt-ssl-cfg
            - name: scripts
              configMap:
                name: ingress-nginx-k8-certbot-scripts
            - name: dnsmade-easy-api
              secret:
                secretName: dnsmade-easy-api
            - name: letsencrypt-data
              persistentVolumeClaim:
                claimName: letsencrypt-data
```
