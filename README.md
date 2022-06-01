# Test Flux AWS KMS

# How to
1. Review `terraform/main.tf` and execute the terraform project.
2. Connect to the recently created cluster with the command provided by the terraform outputs (configure_kubectl).
3. Look for and replace in the folder `cluster` the following strings (they are surrounded with <>):
	- KMS_KEY_ARN -> terraform output decrypt_kms_key
	- KMS_ROLE_ARN -> terraform output decrypt_secrets_role
	- GIT_USERNAME -> your repo username for cloning
	- GIT_PASSWORD -> your repo password for cloninig
	- GIT_REPOSITORY -> your repo url for cloning
4. Install flux by executing `kubectl apply -f cluster/base/flux-system.yaml`. And configure the synching with `kubectl apply -k cluster/base`.
5. Restart flux kustomize-controller `kubectl -n flux-system rollout restart deployment/kustomize-controller`.
6. Go to directory `cluster/default` and issue `sops config.sops.yaml` to create a file with the following:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: config
  namespace: default
stringData:
  testKey: "data"
```
7. Commit to your repo the file, and force a reconciliation with `flux -n default reconcile kustomization default --with-source`. It fails with **AccessDeniedException**.