# Create a cluster with KCli

[KCli Project](https://github.com/karmab/kcli)

1. Deploy a K8s cluster using KCli

    ~~~sh
    kcli create kube generic -P masters=1 -P workers=1  -P master_memory=4096 -P numcpus=2 -P worker_memory=4096 -P sdn=calico -P version=1.18 -P ingress=true -P ingress_method=nginx -P metallb=true code-to-prod-cluster
    ~~~
2. Once deployed configure a demo domain name in dnsmasq for the Ingress Controller

    > **NOTE**: I will use NetworkManager DNSMasq, feel free to use something different in your env
    1. Get the NGinx Ingress SVC IP
    
        ~~~sh
        NGINX_CONTROLLER_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[*].ip}')
        ~~~

    2. Configure the DNS domain for the Ingress Controller
        ~~~sh
        sudo echo "address=/mario.lab/${NGINX_CONTROLLER_IP}" > /etc/NetworkManager/dnsmasq.d/mario.lab
        ~~~
3. Deploy Argo CD

    ~~~sh
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v1.6.1/manifests/install.yaml
    ~~~
4. Get the Argo CD admin user password

    ~~~sh
    mkdir -p /var/tmp/code-to-prod-demo/
    ARGOCD_PASSWORD=$(kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server -o name | awk -F "/" '{print $2}')
    echo $ARGOCD_PASSWORD > /var/tmp/code-to-prod-demo/argocd-password
    ~~~
5. Patch the NGINX Ingress controller to support ssl-passthrough

    ~~~sh
    kubectl -n ingress-nginx patch deployment ingress-nginx-controller -p '{"spec":{"template":{"spec":{"$setElementOrder/containers":[{"name":"controller"}],"containers":[{"args":["/nginx-ingress-controller","--election-id=ingress-controller-leader","--ingress-class=nginx","--configmap=ingress-nginx/ingress-nginx-controller","--validating-webhook=:8443","--validating-webhook-certificate=/usr/local/certificates/cert","--validating-webhook-key=/usr/local/certificates/key","--publish-status-address=localhost","--enable-ssl-passthrough"],"name":"controller"}]}}}}'
    ~~~
6.  Create an ingress object for accessing Argo CD WebUI
     
    > **NOTE**: You need to use your own hostname for the Ingress hostname

    ~~~sh
    cat <<EOF | kubectl -n argocd apply -f -
    apiVersion: extensions/v1beta1
    kind: Ingress
    metadata:
      name: argocd-server-ingress
      annotations:
        kubernetes.io/ingress.class: nginx
        nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
        nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    spec:
      rules:
      - host: argocd.mario.lab
        http:
          paths:
          - backend:
              serviceName: argocd-server
              servicePort: https
    EOF
    ~~~
7.  Deploy Tekton Pipelines, Tekton Triggers and Tekton Dashboard

    ~~~sh
    kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/previous/v0.12.1/release.yaml
    kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/previous/v0.5.0/release.yaml
    kubectl apply -f https://github.com/tektoncd/dashboard/releases/download/v0.7.1/tekton-dashboard-release.yaml
    ~~~

# Create the required Tekton manifests

1. Clone the Git repositories (you will need the ssh keys are already in place)

    > **NOTE**: You need to fork these repositories and use your fork (so you have full-access)

    ~~~sh
    git clone git@github.com:mvazquezc/reverse-words.git /var/tmp/code-to-prod-demo/reverse-words
    git clone git@github.com:mvazquezc/reverse-words-cicd.git /var/tmp/code-to-prod-demo/reverse-words-cicd
    ~~~
2. Go to the reverse-words-cicd repo and checkout the CI branch which contains our Tekton manifests

    ~~~sh
    cd /var/tmp/code-to-prod-demo/reverse-words-cicd
    git checkout ci
    ~~~
3. Create a namespace for storing the configuration for our reversewords app pipeline

    ~~~sh
    kubectl create namespace tekton-reversewords
    ~~~
4. Add the quay credentials to the credentials file

    ~~~sh
    QUAY_USER=<your_user>
    read -s QUAY_PASSWORD
    sed -i "s/<username>/$QUAY_USER/" quay-credentials.yaml
    sed -i "s/<password>/$QUAY_PASSWORD/" quay-credentials.yaml
    ~~~
5. Create a Secret containing the credentials to access our Git repository

    > **NOTE**: You need to provide a token with push access to the cicd repository
    
    ~~~sh
    read -s GIT_AUTH_TOKEN
    kubectl -n tekton-reversewords create secret generic image-updater-secret --from-literal=token=${GIT_AUTH_TOKEN}
    ~~~
6. Import credentials into the cluster

    ~~~sh
    kubectl -n tekton-reversewords create -f quay-credentials.yaml
    ~~~
7. Create a ServiceAccount with access to the credentials created in the previous step

    ~~~sh
    kubectl -n tekton-reversewords create -f pipeline-sa.yaml
    ~~~
8. Create the Linter Task which will lint our code

    ~~~sh
    kubectl -n tekton-reversewords create -f lint-task.yaml
    ~~~
9. Create the Tester Task which will run the tests in our app

    ~~~sh
    kubectl -n tekton-reversewords create -f test-task.yaml
    ~~~
10. Create the Builder Task which will build a container image for our app

    ~~~sh
    kubectl -n tekton-reversewords create -f build-task.yaml
    ~~~
11. Create the Image Update Task which will update the Deployment on a given branch after a successful image build

    ~~~sh
    kubectl -n tekton-reversewords create -f image-updater-task.yaml
    ~~~
12. Edit some parameters from our Build Pipeline definition
    
    > **NOTE**: You need to use your forks address in the substitutions below

    ~~~sh
    sed -i "s|<reversewords_git_repo>|https://github.com/mvazquezc/reverse-words|" build-pipeline.yaml
    sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" build-pipeline.yaml
    sed -i "s|<golang_package>|github.com/mvazquezc/reverse-words|" build-pipeline.yaml
    sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" build-pipeline.yaml
    ~~~
13. Create the Build Pipeline definition which will be used to execute the previous tasks in an specific order with specific parameters

    ~~~sh
    kubectl -n tekton-reversewords create -f build-pipeline.yaml
    ~~~
14. Create the curl task which will be used to query our apps on the promoter pipeline

    ~~~sh
    kubectl -n tekton-reversewords create -f curl-task.yaml
    ~~~
15. Create the task that gets the stage release from the git cicd repository

    ~~~sh
    kubectl -n tekton-reversewords create -f get-stage-release-task.yaml
    ~~~
16. Edit some parameters from our Promoter Pipeline definition

    > **NOTE**: You need to use your forks address/quay account in the substitutions below

    ~~~sh
    sed -i "s|<reversewords_cicd_git_repo>|https://github.com/mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
    sed -i "s|<reversewords_quay_repo>|quay.io/mavazque/tekton-reversewords|" promote-to-prod-pipeline.yaml
    sed -i "s|<imageBuilder_sourcerepo>|mvazquezc/reverse-words-cicd|" promote-to-prod-pipeline.yaml
    sed -i "s|<stage_deployment_file_path>|./deployment.yaml|" promote-to-prod-pipeline.yaml
    ~~~
17. Create the Promoter Pipeline definition which will be used to execute the previous tasks in an specific order with specific parameters

    ~~~sh
    kubectl -n tekton-reversewords create -f promote-to-prod-pipeline.yaml
    ~~~
18. Create the required Roles and RoleBindings for working with Webhooks

    ~~~sh
    kubectl -n tekton-reversewords create -f webhook-roles.yaml
    ~~~
19. Create the TriggerBinding for reading data received by a webhook and pass it to the Pipeline

    ~~~sh
    kubectl -n tekton-reversewords create -f github-triggerbinding.yaml
    ~~~
20. Create the TriggerTemplate and Event Listener to run the Pipeline when new commits hit the main branch of our app repository

    ~~~sh
    WEBHOOK_SECRET="v3r1s3cur3"
    kubectl -n tekton-reversewords create secret generic webhook-secret --from-literal=secret=${WEBHOOK_SECRET}
    sed -i "s/<git-triggerbinding>/github-triggerbinding/" webhook.yaml
    kubectl -n tekton-reversewords create -f webhook.yaml
    ~~~
21. We need to provide an ingress point for our EventListener, we want it to be TLS, so we need to generate some certs

    > **NOTE**: Use your own custom hostname for the tekton-events component when generating the key

    ~~~sh
    mkdir -p /var/tmp/code-to-prod-demo/tls-certs/
    cd $_
    openssl genrsa -out tls-certs/tekton-events.key 2048
    openssl req -new -key /var/tmp/code-to-prod-demo/tls-certs/tekton-events.key -out /var/tmp/code-to-prod-demo/tls-certs/tekton-events.csr -subj "/C=US/ST=TX/L=Austin/O=RedHat/CN=tekton-events.mario.lab"
    ~~~
22. Send the CSR to the Kubernetes server to get it signed with the Kubernetes CA
/var/tmp/code-to-prod-demo/
    ~~~sh
    cat <<EOF | kubectl apply -f -
    apiVersion: certificates.k8s.io/v1beta1
    kind: CertificateSigningRequest
    metadata:
      name: tekton-events-tls
    spec:
      request: $(cat /var/tmp/code-to-prod-demo/tls-certs/tekton-events.csr | base64 | tr -d '\n')
      usages:
      - digital signature
      - key encipherment
      - server auth
    EOF
    ~~~
23. Approve the CSR and save the cert into a file

    ~~~sh
    kubectl certificate approve tekton-events-tls
    kubectl get csr tekton-events-tls -o jsonpath='{.status.certificate}' | base64 -d > /var/tmp/code-to-prod-demo/tls-certs/tekton-events.crt
    ~~~
24. Create a secret with the TLS certificates

    ~~~sh
    cd /var/tmp/code-to-prod-demo/tls-certs/
    kubectl -n tekton-reversewords create secret generic tekton-events-tls --from-file=tls.crt=tekton-events.crt --from-file=tls.key=tekton-events.key
    ~~~
25. Configure a TLS ingress which uses the certs created

    > **NOTE**: Use your own custom hostname

    ~~~sh
    cat <<EOF | kubectl -n tekton-reversewords create -f -
    apiVersion: networking.k8s.io/v1beta1
    kind: Ingress
    metadata:
      name: github-webhook-eventlistener
      annotations:
        kubernetes.io/ingress.class: nginx
        nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    spec:
      tls:
        - hosts:
          - tekton-events.mario.lab
          secretName: tekton-events-tls
      rules:
      - host: tekton-events.mario.lab
        http:
          paths:
          - backend:
              serviceName: el-reversewords-webhook
              servicePort: 8080
    EOF
    ~~~
26. We need to provide an ingress point for the Tekton Dashboard, we want it to be TLS, so we need to generate some certs

    > **NOTE**: Use your own custom hostname for the tekton-dashboard component when generating the key

    ~~~sh
    cd /var/tmp/code-to-prod-demo/tls-certs/
    openssl genrsa -out /var/tmp/code-to-prod-demo/tls-certs/tekton-dashboard.key 2048
    openssl req -new -key /var/tmp/code-to-prod-demo/tls-certs/tekton-dashboard.key -out /var/tmp/code-to-prod-demo/tls-certs/tekton-dashboard.csr -subj "/C=US/ST=TX/L=Austin/O=RedHat/CN=tekton-dashboard.mario.lab"
    ~~~
27. Send the CSR to the Kubernetes server to get it signed with the Kubernetes CA

    ~~~sh
    cat <<EOF | kubectl apply -f -
    apiVersion: certificates.k8s.io/v1beta1
    kind: CertificateSigningRequest
    metadata:
      name: tekton-dashboard-tls
    spec:
      request: $(cat /var/tmp/code-to-prod-demo/tls-certs/tekton-dashboard.csr | base64 | tr -d '\n')
      usages:
      - digital signature
      - key encipherment
      - server auth
    EOF
    ~~~
28. Approve the CSR and save the cert into a file

    ~~~sh
    kubectl certificate approve tekton-dashboard-tls
    kubectl get csr tekton-dashboard-tls -o jsonpath='{.status.certificate}' | base64 -d > /var/tmp/code-to-prod-demo/tls-certs/tekton-dashboard.crt
    ~~~
29. Create a secret with the TLS certificates

    ~~~sh
    cd /var/tmp/code-to-prod-demo/tls-certs/
    kubectl -n tekton-pipelines create secret generic tekton-dashboard-tls --from-file=tls.crt=tekton-dashboard.crt --from-file=tls.key=tekton-dashboard.key
    ~~~
30. Configure a TLS ingress which uses the certs created

    > **NOTE**: Use your own custom hostname

    ~~~sh
    cat <<EOF | kubectl -n tekton-pipelines create -f -
    apiVersion: networking.k8s.io/v1beta1
    kind: Ingress
    metadata:
      name: github-webhook-eventlistener
      annotations:
        kubernetes.io/ingress.class: nginx
        nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    spec:
      tls:
        - hosts:
          - tekton-dashboard.mario.lab
          secretName: tekton-dashboard-tls
      rules:
      - host: tekton-dashboard.mario.lab
        http:
          paths:
          - backend:
              serviceName: tekton-dashboard
              servicePort: 9097
    EOF
    ~~~

# Configure Argo CD

1. Install the Argo CD Cli to make things easier

    ~~~sh
    # Get the Argo CD Cli and place it in /usr/bin/
    sudo curl -L https://github.com/argoproj/argo-cd/releases/download/v1.6.1/argocd-linux-amd64 -o /usr/bin/argocd
    sudo chmod +x /usr/bin/argocd
    ~~~
2. Login into Argo CD from the Cli

    > **NOTE**: Use your custom Argo CD ingress for login
    
    ~~~sh
    argocd login argocd.mario.lab --insecure --username admin --password $(cat /var/tmp/code-to-prod-demo/argocd-password)
    ~~~
3. Update Argo CD password

    ~~~sh
    argocd account update-password --account admin --current-password $(cat /var/tmp/code-to-prod-demo/argocd-password) --new-password 'r3dh4t1!'
    ~~~
