#!/bin/bash

echo -ne "Enter your quay.io username: "
read QUAY_USER
echo -ne "Enter your quay.io password: "
read -s QUAY_PASSWORD
echo -ne "\nEnter your Git Token: "
read -s GIT_AUTH_TOKEN

echo ""
rm -rf /var/tmp/code-to-prod-demo/
mkdir -p /var/tmp/code-to-prod-demo/
echo "Deploy Argo CD"
oc create namespace argocd
cat <<EOF | oc -n argocd create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: argocd-operatorgroup
spec:
  targetNamespaces:
  - argocd
EOF
cat <<EOF | oc -n argocd create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: argocd-operator
spec:
  channel: alpha
  name: argocd-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
# TODO: wait for subscription instead of sleeping
sleep 120
# Create ArgoCD instance
cat <<EOF | oc -n argocd apply -f -
apiVersion: argoproj.io/v1alpha1
kind: ArgoCD
metadata:
  name: argocd
  namespace: argocd
spec:
  server:
    route:
      enabled: true
  dex:
    openShiftOAuth: true
    image: quay.io/redhat-cop/dex
    version: v2.22.0-openshift
  resourceCustomizations: |
    route.openshift.io/Route:
      ignoreDifferences: |
        jsonPointers:
        - /spec/host
    extensions/Ingress:
      health.lua: |
        hs = {}
        hs.status = "Healthy"
        return hs
  rbac:
    defaultPolicy: ''
    policy: |
      g, system:cluster-admins, role:admin
      g, admins, role:admin
      g, developer, role:developer
      g, marketing, role:marketing
    scopes: '[groups]'
EOF
sleep 120
ARGOCD_PASSWORD=$(oc -n argocd get secret argocd-cluster -o jsonpath='{.data.admin\.password}' | base64 -d)
echo "Deploy Tekton Pipelines and Events"
cat <<EOF | oc -n openshift-operators create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
spec:
  channel: ocp-4.6
  installPlanApproval: Automatic
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
# TODO: wait for subscription instead of sleeping
sleep 120
mkdir -p /var/tmp/code-to-prod-demo
git clone git@github.com:mvazquezc/reverse-words.git /var/tmp/code-to-prod-demo/reverse-words
git clone git@github.com:mvazquezc/reverse-words-cicd.git /var/tmp/code-to-prod-demo/reverse-words-cicd
cd /var/tmp/code-to-prod-demo/reverse-words-cicd
git checkout ci
sleep 10
echo "Create Tekton resources for the demo"
oc create namespace reversewords-ci
sed -i "s/<username>/$QUAY_USER/" quay-credentials.yaml
sed -i "s/<password>/$QUAY_PASSWORD/" quay-credentials.yaml
oc -n reversewords-ci create secret generic image-updater-secret --from-literal=token=${GIT_AUTH_TOKEN}
oc -n reversewords-ci create -f quay-credentials.yaml
oc -n reversewords-ci create -f pipeline-sa.yaml
oc -n reversewords-ci create -f lint-task.yaml
oc -n reversewords-ci create -f test-task.yaml
oc -n reversewords-ci create -f build-task.yaml
oc -n reversewords-ci create -f image-updater-task.yaml
sed -i "s|<reversewords_git_repo>|https://github.com/mvazquezc/reverse-words|" build-pipeline.yaml
sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" build-pipeline.yaml
sed -i "s|<golang_package>|github.com/mvazquezc/reverse-words|" build-pipeline.yaml
sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" build-pipeline.yaml
oc -n reversewords-ci create -f build-pipeline.yaml
oc -n reversewords-ci create -f webhook-roles.yaml
oc -n reversewords-ci create -f github-triggerbinding.yaml
WEBHOOK_SECRET="v3r1s3cur3"
oc -n reversewords-ci create secret generic webhook-secret --from-literal=secret=${WEBHOOK_SECRET}
sed -i "s/<git-triggerbinding>/github-triggerbinding/" webhook.yaml
sed -i "s/- name: pipeline-binding/- name: github-triggerbinding/" webhook.yaml
oc -n reversewords-ci create -f webhook.yaml
oc -n reversewords-ci create -f curl-task.yaml
oc -n reversewords-ci create -f get-stage-release-task.yaml
sed -i "s|<reversewords_cicd_git_repo>|https://github.com/mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" promote-to-prod-pipeline.yaml
sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
sed -i "s|<stage_deployment_file_path>|./deployment.yaml|" promote-to-prod-pipeline.yaml
oc -n reversewords-ci create -f promote-to-prod-pipeline.yaml
oc -n reversewords-ci create route edge reversewords-webhook --service=el-reversewords-webhook --port=8080 --insecure-policy=Redirect
sleep 15
ARGOCD_ROUTE=$(oc -n argocd get route argocd-server -o jsonpath='{.spec.host}')
argocd login $ARGOCD_ROUTE --insecure --username admin --password $ARGOCD_PASSWORD
CONSOLE_ROUTE=$(oc -n openshift-console get route console -o jsonpath='{.spec.host}')
echo "Argo CD Console: $ARGOCD_ROUTE"
echo "Argo CD Admin Password: $ARGOCD_PASSWORD"
echo "OCP Console: $CONSOLE_ROUTE"
